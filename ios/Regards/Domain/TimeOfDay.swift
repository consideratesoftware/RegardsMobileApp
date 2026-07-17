import Foundation

/// A wall-clock time ignoring date + timezone. Used by reminder-window ranges
/// and quiet-hours. Stored as minutes-since-midnight so range comparisons are
/// cheap integer math (ARCHITECTURE.md §9).
public struct TimeOfDay: Sendable, Codable, Equatable, Hashable, Comparable {
    public let minutesSinceMidnight: Int

    public init(minutesSinceMidnight: Int) {
        precondition((0..<1440).contains(minutesSinceMidnight),
                     "TimeOfDay must be within [0, 1440) — got \(minutesSinceMidnight)")
        self.minutesSinceMidnight = minutesSinceMidnight
    }

    public init(hour: Int, minute: Int = 0) {
        self.init(minutesSinceMidnight: hour * 60 + minute)
    }

    // The memberwise `init` traps on out-of-range values, but the synthesized
    // `Decodable` conformance bypasses it — it assigns the stored property
    // directly. A corrupt DB row (`minutesSinceMidnight: 2000`) would then flow
    // straight into calendar math (R38). Enforce the range on decode too, as a
    // recoverable error rather than a trap, since decoding untrusted persisted
    // JSON must never crash the app.
    private enum CodingKeys: String, CodingKey { case minutesSinceMidnight }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minutes = try container.decode(Int.self, forKey: .minutesSinceMidnight)
        guard (0..<1440).contains(minutes) else {
            throw DecodingError.dataCorruptedError(
                forKey: .minutesSinceMidnight, in: container,
                debugDescription: "TimeOfDay must be within [0, 1440) — got \(minutes)")
        }
        self.init(minutesSinceMidnight: minutes)
    }

    public var hour: Int { minutesSinceMidnight / 60 }
    public var minute: Int { minutesSinceMidnight % 60 }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }

    public static let midnight = TimeOfDay(hour: 0)
    public static let endOfDay = TimeOfDay(minutesSinceMidnight: 1439)
}

/// A half-open time range `[start, end)` within a single day. Ranges may wrap
/// across midnight — e.g. quiet-hours `22:30 → 07:30` — in which case `start`
/// > `end` and `contains(_:)` tests membership accordingly.
public struct TimeRange: Sendable, Codable, Equatable, Hashable {
    public let start: TimeOfDay
    public let end: TimeOfDay

    public init(start: TimeOfDay, end: TimeOfDay) {
        self.start = start
        self.end = end
    }

    public var wrapsMidnight: Bool { start > end }

    public func contains(_ time: TimeOfDay) -> Bool {
        if start == end { return false }                  // zero-length range
        if wrapsMidnight {
            return time >= start || time < end
        }
        return time >= start && time < end
    }
}
