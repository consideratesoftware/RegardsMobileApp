import Foundation

/// Why a reminder exists (ARCHITECTURE.md §7, §9).
public enum ReminderKind: String, Codable, Sendable, CaseIterable {
    case cadence
    case birthday
    case anniversary
    case customOccasion = "custom_occasion"
}

/// Lifecycle state of a scheduled reminder.
public enum ReminderState: String, Codable, Sendable, CaseIterable {
    case pending
    case fired
    case cancelled
    case userCaughtUp = "user_caught_up"
}

/// A single scheduled reminder (ARCHITECTURE.md §7). The concrete OS-level
/// notification identifier (`osNotificationId`) lets the platform adapter
/// cancel/replace it when the engine reschedules.
public struct ScheduledReminder: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let contactId: UUID
    public var kind: ReminderKind
    /// ISO month-day (e.g. "02-29") for annual-recurrence kinds; nil for cadence.
    public var occasionDate: String?
    /// Free-text label for anniversaries / custom occasions.
    public var occasionLabel: String?
    public var scheduledFor: Date
    public var osNotificationId: String
    public var state: ReminderState
    /// The raw floor Snooze set (§7 v3, §9): `scheduledFor` is that floor
    /// resolved into a window slot. SchedulingPass reads it only from a
    /// pending cadence row whose slot hasn't started. A row in another state
    /// may still carry a stale floor until the reschedule rewrites the row.
    public var snoozedUntil: Date?

    public init(
        id: UUID = UUID(),
        contactId: UUID,
        kind: ReminderKind,
        occasionDate: String? = nil,
        occasionLabel: String? = nil,
        scheduledFor: Date,
        osNotificationId: String,
        state: ReminderState = .pending,
        snoozedUntil: Date? = nil
    ) {
        self.id = id
        self.contactId = contactId
        self.kind = kind
        self.occasionDate = occasionDate
        self.occasionLabel = occasionLabel
        self.scheduledFor = scheduledFor
        self.osNotificationId = osNotificationId
        self.state = state
        self.snoozedUntil = snoozedUntil
    }
}

/// One annual occasion for a contact (§9 "Annual recurrence"), as the
/// occasion source hands it to SchedulingPass. Regards never stores these
/// (§7); the pass re-reads them on every run and writes the next occurrence
/// as a `ScheduledReminder`.
public struct ContactOccasion: Sendable, Equatable {
    public let contactId: UUID
    /// `.birthday`, `.anniversary`, or `.customOccasion`.
    public let kind: ReminderKind
    public let monthDay: MonthDay
    public let label: String?

    public init(contactId: UUID, kind: ReminderKind, monthDay: MonthDay, label: String? = nil) {
        self.contactId = contactId
        self.kind = kind
        self.monthDay = monthDay
        self.label = label
    }
}
