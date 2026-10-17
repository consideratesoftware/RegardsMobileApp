import Foundation
import Testing
@testable import Regards

/// `nextAllowedSlot` around Lord Howe's 30-minute DST shifts: spring-forward
/// Sun Oct 4 2026 (02:00 +10:30 -> 02:30 +11:00) and fall-back Sun Apr 5 2026
/// (02:00 +11:00 -> 01:30 +10:30). A returned slot start must read a
/// wall-clock time inside its slot.
struct ReminderEngineLordHoweTests {

    private static let zone = "Australia/Lord_Howe"

    @Test(
        "A Sunday slot starting after the spring-forward gap never starts before its wall-clock start",
        arguments: [true, false]
    )
    func slotStartingAfterTheGapDoesNotStartInsideIt(includingContainingSlot: Bool) {
        // Sunday-only 02:45-03:30; 02:30 +11:00 is the first instant of the day
        // after the gap, and it reads 02:30, before the slot opens.
        let window = ReminderWindow(
            allowedDays: .sunday,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 2, minute: 45), end: TimeOfDay(hour: 3, minute: 30))],
            quietHours: nil, timezoneIdentifier: Self.zone)
        let probe = EngineFixtures.date("2026-10-03T12:00:00+10:30")

        let slot = EngineFixtures.engine(now: probe).nextAllowedSlot(
            from: probe, in: window, includingContainingSlot: includingContainingSlot)

        #expect(slot == EngineFixtures.date("2026-10-04T02:45:00+11:00"))
    }

    struct Week: Sendable, CustomTestStringConvertible {
        let name: String
        let first: String
        let last: String

        var testDescription: String { name }
    }

    static let weeks = [
        Week(name: "spring-forward week", first: "2026-10-03T00:00:00+10:30", last: "2026-10-05T00:00:00+11:00"),
        Week(name: "fall-back week", first: "2026-04-04T00:00:00+11:00", last: "2026-04-06T00:00:00+10:30"),
    ]

    @Test(
        "Every returned slot start reads a wall-clock time inside its slot across a Lord Howe transition",
        arguments: weeks, [true, false]
    )
    func everyReturnedSlotStartIsInsideItsSlot(week: Week, includingContainingSlot: Bool) throws {
        let slots = [
            (start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 1, minute: 20)),
            (start: TimeOfDay(hour: 1, minute: 45), end: TimeOfDay(hour: 2, minute: 15)),
            (start: TimeOfDay(hour: 2), end: TimeOfDay(hour: 2, minute: 30)),
            (start: TimeOfDay(hour: 2, minute: 15), end: TimeOfDay(hour: 2, minute: 45)),
            (start: TimeOfDay(hour: 2, minute: 30), end: TimeOfDay(hour: 3)),
            (start: TimeOfDay(hour: 2, minute: 45), end: TimeOfDay(hour: 3, minute: 30)),
            (start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 3)),
        ]
        let timeZone = try #require(TimeZone(identifier: Self.zone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let first = EngineFixtures.date(week.first)
        let probes = Array(stride(from: first, through: EngineFixtures.date(week.last), by: 900))

        var outside: [String] = []
        for slot in slots {
            let window = EngineFixtures.allDaysWindow(
                [TimeRange(start: slot.start, end: slot.end)], tz: Self.zone)
            for probe in probes {
                guard let start = EngineFixtures.engine(now: probe).nextAllowedSlot(
                    from: probe, in: window, includingContainingSlot: includingContainingSlot) else { continue }
                let parts = calendar.dateComponents([.hour, .minute], from: start)
                let wall = TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                if wall < slot.start || wall >= slot.end {
                    outside.append("slot \(slot.start)-\(slot.end) from \(probe): \(start) reads \(wall)")
                }
            }
        }

        #expect(outside.isEmpty, "\(outside.count) slot starts outside their slot, first: \(outside.first ?? "")")
    }
}
