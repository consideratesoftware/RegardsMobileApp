import Foundation

/// Persists a logged interaction and stamps `lastInteractedAt` — the shared
/// two-repository write behind "Caught up" and "Log other channel…"
/// (ARCHITECTURE.md §14 PR22, R11/R46).
///
/// Deliberately **not** a scheduling component: it never reads or writes
/// `ScheduledReminder`, never resolves a reminder window, and never calls
/// `ReminderEngine`. Rescheduling `ScheduledReminder` rows stays exclusively
/// `SchedulingPass`'s job once TF-07 (PR25) builds it (decision #36) — this
/// type only ever touches `ContactRepository` and `InteractionRepository`.
///
/// Snooze is out of scope for this helper for the same reason: decision #31
/// requires pushing a *pending reminder's* `scheduledFor`, which only a
/// `ScheduledReminder` writer can do.
struct InteractionLogging {
    let contacts: any ContactRepository
    let interactions: any InteractionRepository

    /// "Caught up": logs a `.reminderCaughtUp` interaction against the
    /// contact's own preferred channel and moves `lastInteractedAt` to
    /// `occurredAt`. Returns the updated contact so the caller can refresh
    /// local state without a second fetch.
    @discardableResult
    func markCaughtUp(contactId: UUID, at occurredAt: Date) async throws -> Contact {
        guard let contact = try await contacts.fetch(id: contactId) else {
            throw DataError.notFound
        }
        return try await record(
            contact: contact,
            source: .reminderCaughtUp,
            channel: contact.preferredChannel,
            at: occurredAt
        )
    }

    /// "Log other channel…": the same downstream effect as `markCaughtUp` —
    /// reaching a contact through any channel still counts as staying in
    /// touch — logged as `.manual` against the channel the user actually
    /// used.
    @discardableResult
    func logOther(contactId: UUID, channel: Channel, at occurredAt: Date) async throws -> Contact {
        guard let contact = try await contacts.fetch(id: contactId) else {
            throw DataError.notFound
        }
        return try await record(contact: contact, source: .manual, channel: channel, at: occurredAt)
    }

    /// Writes in a fixed order — `interactions.append` before the
    /// `lastInteractedAt` move — with no compensation if the second write
    /// fails. If `append` succeeds and the move then throws, the
    /// `InteractionLog` row is left persisted with no matching
    /// `lastInteractedAt` move: a caller re-reading the contact sees it
    /// still due, while its own interaction history already claims
    /// otherwise. Neither list rereads interaction history to decide
    /// overdue-ness (only `Contact.lastInteractedAt`), so this doesn't
    /// produce a visibly wrong Overdue row — the drift is confined to the
    /// interactions list disagreeing with the contact's own state, and
    /// self-heals the next time this contact is caught up successfully.
    /// Reordering to move-then-append would trade this for the opposite
    /// drift (the contact reads caught-up with no log entry to show for it)
    /// rather than removing it — a stub that doesn't touch
    /// `ScheduledReminder` has no transactional primitive spanning two
    /// repositories to close the gap with; that arrives with SchedulingPass's
    /// full write surface (TF-07 / PR25).
    ///
    /// `contacts.updateLastInteractedAt`, not `contacts.upsert` from the
    /// `contact` snapshot passed in: that snapshot was fetched at the start
    /// of `markCaughtUp`/`logOther`, and a whole-row `upsert` from it could
    /// silently clobber a concurrent `ContactsReconciler` field write
    /// landing on the same row in between — including un-archiving a contact
    /// the reconciler just archived. The field-scoped write never reads the
    /// row, so it can't revert anything it doesn't touch (same reasoning as
    /// `updateReconciledFields`, TF-03).
    ///
    /// Throws on a `false` return, rather than treating "no row matched" as
    /// a quiet success: if the contact was archived or deleted between the
    /// earlier `fetch` and this write, `lastInteractedAt` never actually
    /// moved, and a caller reporting success anyway would announce "Marked
    /// X caught up" for a write that changed nothing (staged review, same
    /// class of false confirmation as blocker 1's occasion-row fix).
    private func record(
        contact: Contact,
        source: InteractionSource,
        channel: Channel?,
        at occurredAt: Date
    ) async throws -> Contact {
        try await interactions.append(
            InteractionLog(contactId: contact.id, occurredAt: occurredAt, source: source, channel: channel)
        )
        let matched = try await contacts.updateLastInteractedAt(id: contact.id, at: occurredAt)
        guard matched else {
            throw DataError.notFound
        }
        var updated = contact
        updated.lastInteractedAt = occurredAt
        return updated
    }
}
