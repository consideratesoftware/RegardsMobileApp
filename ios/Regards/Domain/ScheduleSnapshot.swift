import Foundation

/// One consistent read of everything the reminder screens need (R10), from
/// `ReminderRepository.observeSchedule()`. The screens only read persisted
/// reminders (decision #36). Every value comes from the same transaction, so
/// a row never refers to a contact the snapshot doesn't hold.
public struct ScheduleSnapshot: Sendable, Equatable {
    /// Tracked, active contacts, ordered by `id`.
    public let contacts: [Contact]
    /// Pending and fired rows whose contact is in `contacts`, ordered by
    /// `scheduledFor`, then `id`.
    public let reminders: [ScheduledReminder]
    /// The global window. Per-contact overrides travel on each `Contact`.
    public let window: ReminderWindow

    public init(contacts: [Contact], reminders: [ScheduledReminder], window: ReminderWindow) {
        self.contacts = contacts
        self.reminders = reminders
        self.window = window
    }
}
