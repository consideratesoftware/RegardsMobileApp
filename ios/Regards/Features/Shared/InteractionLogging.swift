import Foundation

/// Persists a logged interaction and stamps `lastInteractedAt` — the shared
/// two-repository write behind "Caught up" and "Log other channel…"
/// (ARCHITECTURE.md §14 PR22, R11/R46).
///
/// Deliberately **not** a scheduling component: it never reads or writes
/// `ScheduledReminder`, never resolves a reminder window, and never calls
/// `ReminderEngine`; it only touches `ContactRepository` and
/// `InteractionRepository`. Only `SchedulingPass.recordInteraction` builds
/// one, inside the pass's lock, so the caught-up transition, these writes,
/// and the reschedule run as one span (decision #36, R60).
///
/// Snooze is out of scope for this helper for the same reason: decision #31
/// requires pushing a *pending reminder's* `scheduledFor`, which only a
/// `ScheduledReminder` writer can do.
struct InteractionLogging {
    let contacts: any ContactRepository
    let interactions: any InteractionRepository

    /// `markCaughtUp(requireCadenceEligible: true)` refused before any write:
    /// the contact is missing or isn't `isCadenceEligible`.
    struct NotCadenceEligible: Error {}

    /// "Caught up": logs a `.reminderCaughtUp` interaction against the
    /// contact's own preferred channel and moves `lastInteractedAt` to
    /// `occurredAt`. Returns the updated contact so the caller can refresh
    /// local state without a second fetch.
    ///
    /// `contact.isActive`, not just a non-nil fetch (staged review round 9):
    /// this is the choke point every `markCaughtUp`/`logOther` call site
    /// funnels through, and without the check here, `record()` would still
    /// append a real `InteractionLog` row before `updateLastInteractedAt`'s
    /// own archived-contact rejection (round 8) ever ran — an orphan log
    /// entry left behind on every failed attempt, with no compensation and
    /// no retry that cleans it up (unlike `contacts.updateLastInteractedAt`
    /// itself, which never partially applies). Checking before either write
    /// runs, in the one place both `markCaughtUp` and `logOther` already
    /// fetch through, matches the point `OverdueViewModel.snooze` and
    /// `ContactDetailViewModel.snooze` already gate at for the identical
    /// archived-mid-session race.
    ///
    /// `requireCadenceEligible` is for Caught up from a notification, which
    /// can outlive the contact's tracking: it throws `NotCadenceEligible`
    /// before any write, checked on the same read the writes use. A Contacts
    /// write landing between this read and `append` can still log one
    /// interaction, the same window the `isActive` check has.
    @discardableResult
    func markCaughtUp(
        contactId: UUID,
        at occurredAt: Date,
        requireCadenceEligible: Bool = false
    ) async throws -> Contact {
        let fetched = try await contacts.fetch(id: contactId)
        if requireCadenceEligible, fetched?.isCadenceEligible != true {
            throw NotCadenceEligible()
        }
        guard let contact = fetched, contact.isActive else {
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
    /// used. Same `contact.isActive` guard as `markCaughtUp`, for the same
    /// orphan-log-row reason — see its doc comment.
    @discardableResult
    func logOther(contactId: UUID, channel: Channel, at occurredAt: Date) async throws -> Contact {
        guard let contact = try await contacts.fetch(id: contactId), contact.isActive else {
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
    /// rather than removing it: there is no transactional primitive spanning
    /// the two repositories to close the gap with.
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
    /// a quiet success: if the contact was deleted — or archived, in the
    /// narrow window after `markCaughtUp`/`logOther`'s own `contact.isActive`
    /// check above already passed but before this write runs — between the
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
