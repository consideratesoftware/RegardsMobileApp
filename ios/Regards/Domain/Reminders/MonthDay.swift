import Foundation

/// Month-day pair for annual-recurrence events (§7). Kept as its own type so
/// Feb-29 handling is explicit at every call site.
public struct MonthDay: Sendable, Equatable, Hashable {
    public let month: Int
    public let day: Int

    public init(month: Int, day: Int) {
        precondition(Self.isValid(month: month, day: day),
                     "\(month)-\(day) is not a valid month-day combination")
        self.month = month
        self.day = day
    }

    /// Failable equivalent of `init` — returns nil on invalid combos instead
    /// of trapping. Preferred entry point for any caller parsing untrusted
    /// input (e.g. deserialized from system Contacts or user form fields).
    public static func make(month: Int, day: Int) -> MonthDay? {
        guard isValid(month: month, day: day) else { return nil }
        return MonthDay(month: month, day: day)
    }

    /// Validate by round-tripping `(month, day)` through a Gregorian calendar
    /// in a leap year (so Feb 29 passes). A rolled-forward result (Nov 31 →
    /// Dec 1, month 13 → next year) doesn't match the input and is rejected.
    private static func isValid(month: Int, day: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var components = DateComponents()
        components.year = 2024   // leap year — validates Feb 29 alongside the rest
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return false }
        let normalized = calendar.dateComponents([.month, .day], from: date)
        return normalized.month == month && normalized.day == day
    }

    /// ISO "MM-DD" used as `ScheduledReminder.occasionDate`.
    public var isoString: String {
        String(format: "%02d-%02d", month, day)
    }

    public static func from(isoString: String) -> MonthDay? {
        let parts = isoString.split(separator: "-")
        guard parts.count == 2,
              let m = Int(parts[0]), let d = Int(parts[1]) else { return nil }
        return make(month: m, day: d)
    }
}
