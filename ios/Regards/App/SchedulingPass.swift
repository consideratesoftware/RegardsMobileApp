import Foundation

/// The §14 PR22 DB-only stub of `SchedulingPass` (decision #36:
/// "`SchedulingPass` actor is the sole writer of `ScheduledReminder` rows and
/// OS notifications"). This slice's entire surface is Snooze: pushing a
/// contact's cadence reminder 7 days out via a direct `ScheduledReminder`
/// upsert.
///
/// There is no reconciliation, batching, occasion handling, or no-double-up
/// suppression here, no `NotificationScheduling` call, and neither
/// `runFull()` nor the general `run(for contactId:)` from §9a's full
/// contract — TF-07 (PR25) absorbs this type and builds all of that on top
/// of it. Every write below stays inside `ReminderRepository`; nothing here
/// touches `ContactRepository` or `InteractionRepository` (`Caught up` and
/// `Log other` go through `InteractionLogging` instead, which never touches
/// `ScheduledReminder`).
public actor SchedulingPass {
    private let reminders: any ReminderRepository
    private let clock: @Sendable () -> Date

    public init(
        reminders: any ReminderRepository,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reminders = reminders
        self.clock = clock
    }

    /// Snooze 1 week (decision #31): pushes the contact's cadence reminder to
    /// fire `now + 7 days`; state stays `.pending`. No interaction is logged
    /// and `lastInteractedAt` is never touched — snoozing is not talking to
    /// someone.
    ///
    /// Idempotent by re-push, not by stacking: calling this again computes a
    /// fresh `now + 7 days` from *that* call's clock reading, replacing
    /// whatever target the previous snooze set — it does not add 7 more days
    /// on top of an already-snoozed date. Repeated snoozing always means
    /// "one more week from right now."
    ///
    /// §9's full contract resolves `nextAllowedSlot(from: firedAt + 7d, in:
    /// effectiveWindow)` — window- and quiet-hours-aware. This DB-only stub
    /// skips that resolution entirely (no `ReminderWindow`, no
    /// `ReminderEngine` dependency here); PR25 fills it in when
    /// `SchedulingPass` gains its full read/write surface.
    public func snooze(contactId: UUID) async throws {
        let newTarget = clock().addingTimeInterval(7 * 86_400)
        let existingCadenceReminder = try await reminders
            .fetchPending(forContact: contactId)
            .first { $0.kind == .cadence }

        var reminder = existingCadenceReminder ?? ScheduledReminder(
            contactId: contactId,
            kind: .cadence,
            scheduledFor: newTarget,
            osNotificationId: Self.cadenceNotificationId(contactId: contactId)
        )
        reminder.scheduledFor = newTarget
        reminder.state = .pending
        try await reminders.upsert(reminder)
    }

    private static func cadenceNotificationId(contactId: UUID) -> String {
        "contact-\(contactId.uuidString)-\(ReminderKind.cadence.rawValue)"
    }
}
