import Foundation
import Testing
@testable import Regards

/// Gap-only Sundays (R62) where the transition lands at midnight, and probes
/// on the gap Sunday itself before the gap.
struct ReminderEngineMidnightGapTests {

    struct Scenario: Sendable, CustomTestStringConvertible {
        let zone: String
        let firstProbe: String
        let lastProbe: String
        let expected: String

        var testDescription: String { zone }
    }

    /// Both zones lose Sunday 00:00-01:00 (Beirut Mar 29 2026, Santiago Sep 6
    /// 2026), so a Sunday-only 00:00-00:30 window has no real instant that day.
    /// Probes run from just after the previous Sunday's slot to just before
    /// the gap Sunday.
    static let scenarios = [
        Scenario(zone: "Asia/Beirut", firstProbe: "2026-03-22T00:30:00+02:00",
                 lastProbe: "2026-03-28T23:00:00+02:00", expected: "2026-04-05T00:00:00+03:00"),
        Scenario(zone: "America/Santiago", firstProbe: "2026-08-30T00:30:00-04:00",
                 lastProbe: "2026-09-05T23:00:00-04:00", expected: "2026-09-13T00:00:00-03:00"),
    ]

    @Test(
        "A Sunday-only midnight window emptied by a midnight DST change reaches the next Sunday",
        arguments: scenarios, [true, false]
    )
    func midnightGapSundayReachesNextOccurrence(scenario: Scenario, includingContainingSlot: Bool) {
        let window = ReminderWindow(
            allowedDays: .sunday,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 0, minute: 30))],
            quietHours: nil, timezoneIdentifier: scenario.zone)
        let expected = EngineFixtures.date(scenario.expected)
        let probes = EngineFixtures.hourlyInstants(
            from: EngineFixtures.date(scenario.firstProbe), through: EngineFixtures.date(scenario.lastProbe))
        #expect(probes.count > 140)

        let misses = probes.filter { probe in
            EngineFixtures.engine(now: probe).nextAllowedSlot(
                from: probe, in: window, includingContainingSlot: includingContainingSlot) != expected
        }

        #expect(misses.isEmpty, "\(misses.count) of \(probes.count) probes missed, first at \(misses.first as Any)")
    }

    @Test(
        "On the spring-forward Sunday before the gap, a gap-only window still reaches next Sunday",
        arguments: [true, false]
    )
    func probeOnGapSundayBeforeTheGapReachesNextSunday(includingContainingSlot: Bool) {
        // Sun Mar 8 2026 in New York: 02:00 -> 03:00, and the only slot is
        // Sunday 02:00-02:30, which does not exist that day.
        let window = ReminderWindow(
            allowedDays: .sunday,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 2), end: TimeOfDay(hour: 2, minute: 30))],
            quietHours: nil, timezoneIdentifier: "America/New_York")
        let expected = EngineFixtures.date("2026-03-15 02:00", tz: "America/New_York")

        for minute in stride(from: 0, through: 59, by: 1) {
            let probe = EngineFixtures.date("2026-03-08 01:\(String(format: "%02d", minute))", tz: "America/New_York")
            let slot = EngineFixtures.engine(now: probe).nextAllowedSlot(
                from: probe, in: window, includingContainingSlot: includingContainingSlot)

            #expect(slot == expected, "probe 01:\(minute) found \(slot as Any)")
        }
    }
}
