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
