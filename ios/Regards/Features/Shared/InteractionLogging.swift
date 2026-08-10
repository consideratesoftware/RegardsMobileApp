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

    /// Writes in a fixed order — `interactions.append` before
    /// `contacts.upsert` — with no compensation if the second write fails.
    /// If `append` succeeds and `upsert` then throws, the `InteractionLog`
    /// row is left persisted with no matching `lastInteractedAt` move: a
    /// caller re-reading the contact sees it still due, while its own
    /// interaction history already claims otherwise. Neither list rereads
    /// interaction history to decide overdue-ness (only `Contact
    /// .lastInteractedAt`), so this doesn't produce a visibly wrong Overdue
    /// row — the drift is confined to the interactions list disagreeing with
    /// the contact's own state, and self-heals the next time this contact is
    /// caught up successfully. Reordering to upsert-then-append would trade
    /// this for the opposite drift (the contact reads caught-up with no log
    /// entry to show for it) rather than removing it — a stub that doesn't
    /// touch `ScheduledReminder` has no transactional primitive spanning two
    /// repositories to close the gap with; that arrives with SchedulingPass's
    /// full write surface (TF-07 / PR25).
    private func record(
        contact: Contact,
        source: InteractionSource,
        channel: Channel?,
        at occurredAt: Date
    ) async throws -> Contact {
        try await interactions.append(
            InteractionLog(contactId: contact.id, occurredAt: occurredAt, source: source, channel: channel)
        )
        var updated = contact
        updated.lastInteractedAt = occurredAt
        try await contacts.upsert(updated)
        return updated
    }
}
