import Foundation
import Testing
@testable import Regards

/// `ReminderEngine.occasionFireDate` around daylight-saving transitions
/// (§9 contract 4 with contract 1, R5). A quiet end is a wall-clock time, so a
/// transition can skip it, repeat it, or move it across midnight. The rule
/// these tests pin: the result is never before the occurrence, and it is a
/// time the user's clock reads outside quiet hours.
struct OccasionFireDateDSTTests {

    private static func fire(
        _ occurrence: String, quiet: TimeRange?, zone: String
    ) -> (occurrence: Date, fire: Date?) {
        let occurrenceDate = EngineFixtures.date(occurrence)
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))], tz: zone, quiet: quiet)
        let fire = ReminderEngine(clock: { occurrenceDate }).occasionFireDate(
            for: occurrenceDate, in: window, timeZone: window.timeZone)
        return (occurrenceDate, fire)
    }

    @Test("Lord Howe fall-back: a second-pass occurrence fires at that pass's quiet end, not before itself")
    func lordHoweSecondPassOccurrenceFiresAfterItself() {
        // Sun Apr 5 2026: 02:00 +11:00 -> 01:30 +10:30, so 01:30-02:00 happens
        // twice. 01:35 +10:30 is the second pass, inside quiet 01:00-01:45.
        let result = Self.fire(
            "2026-04-05T01:35:00+10:30",
            quiet: TimeRange(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 1, minute: 45)),
            zone: "Australia/Lord_Howe")

        #expect(result.fire == EngineFixtures.date("2026-04-05T01:45:00+10:30"))
        if let fire = result.fire {
            #expect(fire >= result.occurrence, "the result must not be before the occurrence")
        }
    }

    @Test("Lord Howe spring-forward: a quiet end inside the 30-minute gap fires at the gap end")
    func lordHoweQuietEndInPartialGap() {
        // Sun Oct 4 2026: 02:00 +10:30 -> 02:30 +11:00. Quiet 01:00-02:15 ends
        // at a time that does not exist.
        let result = Self.fire(
            "2026-10-04T01:15:00+10:30",
            quiet: TimeRange(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 2, minute: 15)),
            zone: "Australia/Lord_Howe")

        #expect(result.fire == EngineFixtures.date("2026-10-04T02:30:00+11:00"))
    }

    @Test("Los Angeles fall-back: a second-pass occurrence fires at that pass's quiet end")
    func losAngelesSecondPassOccurrenceFiresAfterItself() {
        // Sun Nov 1 2026: 01:00-02:00 happens twice. 01:15 PST is the second
        // pass, inside quiet 00:30-01:30.
        let result = Self.fire(
            "2026-11-01T01:15:00-08:00",
            quiet: TimeRange(start: TimeOfDay(hour: 0, minute: 30), end: TimeOfDay(hour: 1, minute: 30)),
            zone: "America/Los_Angeles")

        #expect(result.fire == EngineFixtures.date("2026-11-01T01:30:00-08:00"))
    }

    @Test("Santiago spring-forward at midnight: an occurrence right after the gap fires at the quiet end")
    func santiagoOccurrenceAfterMidnightGap() {
        // Sun Sep 6 2026: 00:00 -04:00 -> 01:00 -03:00, so 00:00-01:00 does not
        // exist. Quiet 00:00-06:00 starts inside the gap.
        let result = Self.fire(
            "2026-09-06T01:00:00-03:00",
            quiet: TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 6)),
            zone: "America/Santiago")

        #expect(result.fire == EngineFixtures.date("2026-09-06T06:00:00-03:00"))
    }

    @Test("Santiago fall-back at midnight: an occurrence in the repeated hour before midnight fires after itself")
    func santiagoOccurrenceInRepeatedHourBeforeMidnight() {
        // Sat Apr 4 2026: 00:00 Sun -03:00 -> 23:00 Sat -04:00, so 23:00-24:00
        // happens twice. 23:15 -04:00 is the second pass, inside quiet 22:30-23:30.
        let result = Self.fire(
            "2026-04-04T23:15:00-04:00",
            quiet: TimeRange(start: TimeOfDay(hour: 22, minute: 30), end: TimeOfDay(hour: 23, minute: 30)),
            zone: "America/Santiago")

        #expect(result.fire == EngineFixtures.date("2026-04-04T23:30:00-04:00"))
    }

    @Test("A quiet range whose start equals its end leaves the occurrence unchanged")
    func emptyQuietRangeLeavesOccurrenceUnchanged() {
        let quiet = TimeRange(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 7))
        for occurrence in ["2026-06-14T07:00:00-04:00", "2026-06-14T12:00:00-04:00", "2026-06-14T03:00:00-04:00"] {
            let result = Self.fire(occurrence, quiet: quiet, zone: "America/New_York")

            #expect(result.fire == result.occurrence, "\(occurrence) should pass through")
        }
    }

    /// A contact's override window can sit in another zone than the global
    /// one, but occasions follow the global zone's local day (§9 contract 4).
    /// Only the override's quiet hours apply; its zone is ignored. Quiet hours
    /// 22:30-07:30 with the global zone America/New_York and the override in
    /// Europe/London (5 hours ahead in June).
    @Test(
        "An override window in another zone leaves the occasion on the global zone's local day",
        arguments: [
            // New York 07:00 (London 12:00): inside quiet in New York only.
            ("2026-06-14T07:00:00-04:00", "2026-06-14T07:30:00-04:00"),
            // New York 20:00 (London 01:00 next day): inside quiet in London only.
            ("2026-06-14T20:00:00-04:00", "2026-06-14T20:00:00-04:00"),
            // New York 23:00 (London 04:00 next day): quiet runs past the New York day.
            ("2026-06-14T23:00:00-04:00", nil),
        ] as [(String, String?)]
    )
    func mismatchedOverrideZoneFollowsTheGlobalZone(occurrence: String, expected: String?) {
        let override = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))],
            tz: "Europe/London",
            quiet: TimeRange(start: TimeOfDay(hour: 22, minute: 30), end: TimeOfDay(hour: 7, minute: 30)))
        let occurrenceDate = EngineFixtures.date(occurrence)
        let newYork = TimeZone(identifier: "America/New_York") ?? .gmt

        let fire = ReminderEngine(clock: { occurrenceDate })
            .occasionFireDate(for: occurrenceDate, in: override, timeZone: newYork)

        #expect(fire == expected.map { EngineFixtures.date($0) })
    }
}
