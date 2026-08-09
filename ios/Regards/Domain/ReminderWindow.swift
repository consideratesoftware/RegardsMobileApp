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
    public let occasionTime: TimeOfDay
    public let digestHorizonDays: Int

    public static let defaultOccasionTime = TimeOfDay(hour: 9)
    public static let defaultDigestHorizonDays = 14

    public init(
        allowedDays: DayOfWeekMask,
        allowedTimeRanges: [TimeRange],
        quietHours: TimeRange? = nil,
        timezoneIdentifier: String,
        occasionTime: TimeOfDay = ReminderWindow.defaultOccasionTime,
        digestHorizonDays: Int = ReminderWindow.defaultDigestHorizonDays
    ) {
        self.allowedDays = allowedDays
        self.allowedTimeRanges = allowedTimeRanges
        self.quietHours = quietHours
        self.timezoneIdentifier = timezoneIdentifier
        self.occasionTime = occasionTime
        self.digestHorizonDays = digestHorizonDays
    }

    private enum CodingKeys: String, CodingKey {
        case allowedDays
        case allowedTimeRanges
        case quietHours
        case timezoneIdentifier
        case occasionTime
        case digestHorizonDays
    }

    /// Per-contact overrides persisted before v2 don't contain the occasion
    /// or digest fields. Decode those blobs with the v2 defaults so an app
    /// update doesn't invalidate a contact's existing window.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.allowedDays = try container.decode(DayOfWeekMask.self, forKey: .allowedDays)
        self.allowedTimeRanges = try container.decode([TimeRange].self, forKey: .allowedTimeRanges)
        self.quietHours = try container.decodeIfPresent(TimeRange.self, forKey: .quietHours)
        self.timezoneIdentifier = try container.decode(String.self, forKey: .timezoneIdentifier)
        self.occasionTime = try container.decodeIfPresent(
            TimeOfDay.self, forKey: .occasionTime) ?? Self.defaultOccasionTime
        self.digestHorizonDays = try container.decodeIfPresent(
            Int.self, forKey: .digestHorizonDays) ?? Self.defaultDigestHorizonDays
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(allowedDays, forKey: .allowedDays)
        try container.encode(allowedTimeRanges, forKey: .allowedTimeRanges)
        try container.encodeIfPresent(quietHours, forKey: .quietHours)
        try container.encode(timezoneIdentifier, forKey: .timezoneIdentifier)
        try container.encode(occasionTime, forKey: .occasionTime)
        try container.encode(digestHorizonDays, forKey: .digestHorizonDays)
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
        case invalidDigestHorizonDays(Int)
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
        guard [7, 14, 30].contains(digestHorizonDays) else {
            throw ValidationError.invalidDigestHorizonDays(digestHorizonDays)
        }
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
