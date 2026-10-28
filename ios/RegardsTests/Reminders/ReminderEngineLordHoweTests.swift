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

    struct TransitionDay: Sendable, CustomTestStringConvertible {
        let name: String
        let zone: String
        /// Midnight starting the transition day, and the next midnight, as ISO instants.
        let start: String
        let end: String
        let slots: [TimeRange]
        /// How many 5-minute probes read a wall clock inside one of `slots`,
        /// summed over all slots. A wall-clock minute that happens twice (a
        /// fold) is probed twice, and one that is skipped (a gap) not at all,
        /// so these differ from slot widths / 5. Fixed by the tz database.
        let inSlotProbes: Int

        var testDescription: String { name }
    }

    private static func slot(_ startHour: Int, _ startMinute: Int, _ endHour: Int, _ endMinute: Int) -> TimeRange {
        TimeRange(start: TimeOfDay(hour: startHour, minute: startMinute),
                  end: TimeOfDay(hour: endHour, minute: endMinute))
    }

    static let transitionDays = [
        TransitionDay(
            name: "Lord Howe spring-forward", zone: "Australia/Lord_Howe",
            start: "2026-10-04T00:00:00+10:30", end: "2026-10-05T00:00:00+11:00",
            slots: [slot(1, 0, 2, 15), slot(1, 45, 3, 0), slot(2, 0, 2, 40), slot(2, 15, 2, 45),
                    slot(2, 30, 3, 0), slot(2, 45, 3, 30), slot(0, 0, 4, 0)],
            inSlotProbes: 84),
        TransitionDay(
            name: "Lord Howe fall-back", zone: "Australia/Lord_Howe",
            start: "2026-04-05T00:00:00+11:00", end: "2026-04-06T00:00:00+10:30",
            slots: [slot(1, 0, 1, 20), slot(1, 0, 1, 45), slot(1, 15, 2, 15), slot(1, 30, 2, 0),
                    slot(1, 45, 2, 30), slot(1, 30, 3, 0), slot(0, 0, 4, 0)],
            inSlotProbes: 137),
        TransitionDay(
            name: "New York fall-back", zone: "America/New_York",
            start: "2026-11-01T00:00:00-04:00", end: "2026-11-02T00:00:00-05:00",
            slots: [slot(0, 30, 1, 30), slot(1, 0, 2, 0), slot(1, 15, 1, 45), slot(1, 30, 2, 30),
                    slot(1, 45, 3, 0), slot(0, 0, 4, 0)],
            inSlotProbes: 151),
    ]

    @Test(
        "A probe inside a slot on a transition day never returns an instant outside that slot's wall-clock range",
        arguments: transitionDays
    )
    func probeInsideASlotReturnsAnInstantInsideIt(day: TransitionDay) throws {
        let timeZone = try #require(TimeZone(identifier: day.zone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func wallClock(_ date: Date) -> TimeOfDay {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }
        let probes = Array(stride(
            from: EngineFixtures.date(day.start), through: EngineFixtures.date(day.end), by: 300))
        var insideProbes = 0
        var nilCount = 0
        var violations: [String] = []

        for slot in day.slots {
            let window = EngineFixtures.allDaysWindow([slot], tz: day.zone)
            for probe in probes {
                let probeWall = wallClock(probe)
                guard slot.start <= probeWall, probeWall < slot.end else { continue }
                insideProbes += 1
                guard let result = EngineFixtures.engine(now: probe).nextAllowedSlot(
                    from: probe, in: window, includingContainingSlot: true) else {
                    nilCount += 1
                    continue
                }
                let resultWall = wallClock(result)
                if resultWall < slot.start || resultWall >= slot.end {
                    violations.append("slot \(slot.start)-\(slot.end), probe \(probe) -> \(result) reads \(resultWall)")
                }
            }
        }

        #expect(insideProbes == day.inSlotProbes, "the sweep visited \(insideProbes) in-slot probes")
        #expect(nilCount == 0, "a probe inside a slot always has a slot to return, \(nilCount) returned nil")
        #expect(violations.isEmpty, "\(violations.count) violations, first: \(violations.first ?? "")")
    }
}
