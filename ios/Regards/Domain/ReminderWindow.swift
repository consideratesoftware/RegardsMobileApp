import Foundation

/// Global reminder-window preferences (ARCHITECTURE.md §7, §9).
///
/// The single-row `ReminderWindow` table in the DB maps to one `ReminderWindow`
/// value. Per-contact overrides are represented as the same struct nullable on
/// the contact record.
public struct ReminderWindow: Sendable, Codable, Equatable, Hashable {
    public let allowedDays: DayOfWeekMask
    public let allowedTimeRanges: [TimeRange]
    public let quietHours: TimeRange?
    public let timezoneIdentifier: String

    public init(
        allowedDays: DayOfWeekMask,
        allowedTimeRanges: [TimeRange],
        quietHours: TimeRange? = nil,
        timezoneIdentifier: String
    ) {
        self.allowedDays = allowedDays
        self.allowedTimeRanges = allowedTimeRanges
        self.quietHours = quietHours
        self.timezoneIdentifier = timezoneIdentifier
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: timezoneIdentifier) ?? .current
    }

    /// Default V1 window: weekdays 12:00–13:00 + 18:00–22:00, quiet 22:30–07:30.
    /// Matches the mock on screen-misc.jsx::ReminderWindowsScreen.
    public static func defaultV1(timezone: TimeZone = .current) -> ReminderWindow {
        ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [
                TimeRange(start: TimeOfDay(hour: 12), end: TimeOfDay(hour: 13)),
                TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22)),
            ],
            quietHours: TimeRange(start: TimeOfDay(hour: 22, minute: 30),
                                  end: TimeOfDay(hour: 7, minute: 30)),
            timezoneIdentifier: timezone.identifier
        )
    }

    /// Does the given `calendarWeekday` + `time` fall inside any allowed slot
    /// and outside quiet-hours?
    public func isInWindow(calendarWeekday weekday: Int, time: TimeOfDay) -> Bool {
        guard allowedDays.contains(calendarWeekday: weekday) else { return false }
        if let quiet = quietHours, quiet.contains(time) { return false }
        return allowedTimeRanges.contains { $0.contains(time) }
    }

    /// Why a window is structurally invalid (decision #28, §9).
    public enum ValidationError: Error, Equatable, Sendable {
        case noAllowedDays
        case noAllowedTimeRanges
        case zeroLengthRange(TimeRange)
        case wrappingAllowedRange(TimeRange)
        case invalidTimezoneIdentifier(String)
    }

    /// Structural validity per decision #28: an allowed time range must not
    /// wrap midnight (`start < end` strictly). Only **quiet hours** may wrap —
    /// "22:30 → 07:30" is the natural shape there. The scheduling walk can't
    /// honor a wrapping allowed range and the editor never offers one, so we
    /// make the state unrepresentable at validation instead of silently
    /// skipping it (R3).
    ///
    /// This is a purely structural check — it does not compute firing capacity.
    /// A structurally valid window can still have zero capacity once quiet hours
    /// are applied; that case surfaces as `nextAllowedSlot(...) == nil`, which
    /// the window editor also refuses to save (§9 contract 2).
    public func validate() throws {
        guard TimeZone(identifier: timezoneIdentifier) != nil else {
            throw ValidationError.invalidTimezoneIdentifier(timezoneIdentifier)
        }
        guard !allowedDays.isEmpty else { throw ValidationError.noAllowedDays }
        guard !allowedTimeRanges.isEmpty else { throw ValidationError.noAllowedTimeRanges }
        for range in allowedTimeRanges {
            if range.start == range.end { throw ValidationError.zeroLengthRange(range) }
            if range.wrapsMidnight { throw ValidationError.wrappingAllowedRange(range) }
        }
    }

    /// Convenience predicate over `validate()` for editor call sites that only
    /// need a yes/no (the thrown error drives the inline UI message).
    public var isValid: Bool {
        do {
            try validate()
            return true
        } catch {
            return false
        }
    }
}
