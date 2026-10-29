import Foundation
import Testing
@testable import Regards

/// `nextAllowedSlot(includingContainingSlot: true)` reports the start of the
/// slot a probe is inside, and SchedulingPass names a digest after that start
/// (`digest-{epoch}`, §9 contract 5). In a fall-back fold the same wall-clock
/// slot happens twice, so a start from the first pass is a different slot
/// from the one the probe is in, and it collides with the digest that first
/// pass already owns (R63, owner ruling 7 on PR #66).
///
/// The rule: every wall-clock minute from the returned start up to the probe
/// reads inside the slot. A later start (a skipped slot) also passes; R63
/// accepts that residual.
struct ReminderEngineInProgressSlotStartTests {

    struct Fold: Sendable, CustomTestStringConvertible {
        let name: String
        let zone: String
        let slot: TimeRange
        /// The first pass of the repeated slot, as an ISO instant.
        let firstPassProbe: String
        /// Probes in the second pass, the first of them at the slot start.
        let secondPassProbes: [String]
        /// The first-pass start the second pass must not reuse.
        let firstPassStart: String

        var testDescription: String { name }
    }

    private static func range(_ startHour: Int, _ startMinute: Int, _ endHour: Int, _ endMinute: Int) -> TimeRange {
        TimeRange(start: TimeOfDay(hour: startHour, minute: startMinute),
                  end: TimeOfDay(hour: endHour, minute: endMinute))
    }

    static let folds = [
        Fold(name: "Lord Howe 2026-04-05, slot 01:45-02:00", zone: "Australia/Lord_Howe",
             slot: range(1, 45, 2, 0), firstPassProbe: "2026-04-05T01:50:00+11:00",
             secondPassProbes: ["2026-04-05T01:45:00+10:30", "2026-04-05T01:50:00+10:30"],
             firstPassStart: "2026-04-05T01:45:00+11:00"),
        Fold(name: "Antarctica/Troll 2026-10-25, slot 01:15-01:30", zone: "Antarctica/Troll",
             slot: range(1, 15, 1, 30), firstPassProbe: "2026-10-25T01:20:00+02:00",
             secondPassProbes: ["2026-10-25T01:15:00Z", "2026-10-25T01:20:00Z"],
             firstPassStart: "2026-10-25T01:15:00+02:00"),
        Fold(name: "Pacific/Chatham 2026-04-05, slot 02:50-03:00", zone: "Pacific/Chatham",
             slot: range(2, 50, 3, 0), firstPassProbe: "2026-04-05T02:55:00+13:45",
             secondPassProbes: ["2026-04-05T02:50:00+12:45", "2026-04-05T02:55:00+12:45"],
             firstPassStart: "2026-04-05T02:50:00+13:45"),
    ]

    private static func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }

    /// Whether every wall-clock minute from `start` to `probe` reads inside
    /// `slot`. A start after the probe has no minutes in between and counts
    /// as unbroken when it reads inside the slot itself.
    private static func isUnbroken(
        from start: Date, to probe: Date, slot: TimeRange, calendar: Calendar
    ) -> Bool {
        func readsInside(_ instant: Date) -> Bool {
            let parts = calendar.dateComponents([.hour, .minute], from: instant)
            let wall = TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
            return slot.start <= wall && wall < slot.end
        }
        guard readsInside(start) else { return false }
        var instant = start
        while instant <= probe {
            if !readsInside(instant) { return false }
            instant = instant.addingTimeInterval(60)
        }
        return true
    }

    private static func slotStart(_ fold: Fold, probe: String) -> Date? {
        let probeDate = EngineFixtures.date(probe)
        let window = EngineFixtures.allDaysWindow([fold.slot], tz: fold.zone)
        return EngineFixtures.engine(now: probeDate).nextAllowedSlot(
            from: probeDate, in: window, includingContainingSlot: true)
    }

    @Test("A second-pass probe in a fall-back fold never gets a start from the first pass", arguments: folds)
    func secondPassProbeStartIsNotFromTheFirstPass(fold: Fold) throws {
        let calendar = try Self.calendar(fold.zone)
        for probe in fold.secondPassProbes {
            let start = try #require(Self.slotStart(fold, probe: probe), "\(probe) has a slot to return")

            #expect(
                Self.isUnbroken(from: start, to: EngineFixtures.date(probe), slot: fold.slot, calendar: calendar),
                "probe \(probe) returned \(start), which an earlier pass of the slot owns")
        }
    }

    @Test("The first and second pass of a repeated slot get different starts, so their digests differ",
          arguments: folds)
    func repeatedSlotPassesDoNotShareAStart(fold: Fold) throws {
        let firstPassStart = try #require(Self.slotStart(fold, probe: fold.firstPassProbe))
        #expect(firstPassStart == EngineFixtures.date(fold.firstPassStart))

        for probe in fold.secondPassProbes {
            let secondPassStart = try #require(Self.slotStart(fold, probe: probe))

            #expect(secondPassStart != firstPassStart, "probe \(probe) reused the first pass's start")
        }
    }

    @Test("A first-pass probe keeps its first-pass start", arguments: folds)
    func firstPassProbeKeepsItsOwnStart(fold: Fold) throws {
        let calendar = try Self.calendar(fold.zone)
        let probe = EngineFixtures.date(fold.firstPassProbe)

        let start = try #require(Self.slotStart(fold, probe: fold.firstPassProbe))

        #expect(start == EngineFixtures.date(fold.firstPassStart))
        #expect(Self.isUnbroken(from: start, to: probe, slot: fold.slot, calendar: calendar))
    }

    /// The same rule over every 5-minute probe in the slot shapes the
    /// transition-day sweep uses, so a fold the three pins above do not name
    /// is covered too.
    @Test(
        "No probe inside a slot on a transition day gets a start from an earlier interval",
        arguments: ReminderEngineLordHoweTests.transitionDays
    )
    func noProbeOnATransitionDayGetsAnEarlierIntervalsStart(
        day: ReminderEngineLordHoweTests.TransitionDay
    ) throws {
        let calendar = try Self.calendar(day.zone)
        func wallClock(_ date: Date) -> TimeOfDay {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        }
        let probes = Array(stride(
            from: EngineFixtures.date(day.start), through: EngineFixtures.date(day.end), by: 300))
        var checked = 0
        var violations: [String] = []

        for slot in day.slots {
            let window = EngineFixtures.allDaysWindow([slot], tz: day.zone)
            for probe in probes {
                let probeWall = wallClock(probe)
                guard slot.start <= probeWall, probeWall < slot.end,
                      let start = EngineFixtures.engine(now: probe).nextAllowedSlot(
                        from: probe, in: window, includingContainingSlot: true) else { continue }
                checked += 1
                if !Self.isUnbroken(from: start, to: probe, slot: slot, calendar: calendar) {
                    violations.append("slot \(slot.start)-\(slot.end), probe \(probe) -> \(start)")
                }
            }
        }

        #expect(checked == day.inSlotProbes, "the sweep checked \(checked) probes")
        #expect(violations.isEmpty, "\(violations.count) earlier-interval starts, first: \(violations.first ?? "")")
    }
}
