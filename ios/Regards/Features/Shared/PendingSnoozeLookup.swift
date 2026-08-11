import Foundation

/// A contact's pending cadence `ScheduledReminder`'s `scheduledFor`, keyed
/// by contact id — Snooze's only persisted trace (§14 PR22's
/// `SchedulingPass.snooze` stub; no separate "snoozed" flag exists on
/// `Contact`). `OverdueViewModel.makeOverdueRow` and
/// `UpcomingViewModel.buildRows` both fold the result into the same
/// `max(now, overdueAt, snoozedUntil)` / `includingContainingSlot`
/// computation when deciding a row's date — previously two copies of the
/// same three-line `Dictionary` derivation, one per screen.
///
/// The "any pending cadence row means snoozed" semantics this encodes shift
/// under PR25/TF-07: once Upcoming's `ValueObservation` joins `Contact` and
/// `ScheduledReminder` in one read (R10), this caller-side derivation goes
/// away — the TF-07 design already accounts for that, so this file isn't the
/// place to anticipate it further.
enum PendingSnoozeLookup {
    static func snoozedUntilByContact(pendingReminders: [ScheduledReminder]) -> [UUID: Date] {
        Dictionary(
            pendingReminders
                .filter { $0.kind == .cadence }
                .map { ($0.contactId, $0.scheduledFor) },
            // `max($0, $1)`, not "whichever comes last in the array": two
            // pending cadence rows for one contact shouldn't happen (the
            // deterministic `cadenceReminderID` write-path is meant to keep
            // it to one), but if it ever did, picking by array order would
            // make the winner depend on fetch ordering rather than on which
            // row is actually later — `max` is correct regardless of order.
            uniquingKeysWith: { max($0, $1) }
        )
    }
}
