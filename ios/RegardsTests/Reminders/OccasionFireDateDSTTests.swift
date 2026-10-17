import Foundation
import Testing
@testable import Regards

/// `ReminderEngine.occasionFireDate` around daylight-saving transitions
/// (§9 contract 4 with contract 1, R5). A quiet end is a wall-clock time, so a
/// transition can skip it, repeat it, or move it across midnight. The rule
/// these tests pin: the result is never before the occurrence, and it is a
/// time the user's clock reads outside quiet hours.
struct OccasionFireDateDSTTests {

    /// The occasion fire date for `occurrence` under `quiet`, in `zone`. The
    /// zone comes from `TimeZone(identifier:)`, not from the window, as in
    /// production, where the global window supplies it.
    private static func fire(
        _ occurrence: String, quiet: TimeRange?, zone: String
    ) throws -> (occurrence: Date, fire: Date?) {
        let timeZone = try #require(TimeZone(identifier: zone))
        let occurrenceDate = EngineFixtures.date(occurrence)
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))], tz: zone, quiet: quiet)
        let fire = ReminderEngine(clock: { occurrenceDate })
            .occasionFireDate(for: occurrenceDate, in: window, timeZone: timeZone)
        return (occurrenceDate, fire)
    }

    /// What every non-nil result must satisfy: not before the occurrence, on
    /// the occurrence's local day, and reading a wall-clock time outside quiet
    /// hours.
    private static func expectValid(
        _ fire: Date, occurrence: Date, quiet: TimeRange, zone: String, _ note: String = ""
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        let parts = calendar.dateComponents([.hour, .minute], from: fire)
        let wall = TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        #expect(fire >= occurrence, "before the occurrence \(note)")
        #expect(calendar.isDate(fire, inSameDayAs: occurrence), "not on the occurrence's day \(note)")
        #expect(!quiet.contains(wall), "reads \(wall) inside quiet hours \(note)")
    }

    @Test("Lord Howe fall-back: a second-pass occurrence fires at that pass's quiet end, not before itself")
    func lordHoweSecondPassOccurrenceFiresAfterItself() throws {
        // Sun Apr 5 2026: 02:00 +11:00 -> 01:30 +10:30, so 01:30-02:00 happens
        // twice. 01:35 +10:30 is the second pass, inside quiet 01:00-01:45.
        let result = try Self.fire(
            "2026-04-05T01:35:00+10:30",
            quiet: TimeRange(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 1, minute: 45)),
            zone: "Australia/Lord_Howe")

        #expect(result.fire == EngineFixtures.date("2026-04-05T01:45:00+10:30"))
        if let fire = result.fire {
            #expect(fire >= result.occurrence, "the result must not be before the occurrence")
        }
    }

    @Test("Lord Howe spring-forward: a quiet end inside the 30-minute gap fires at the gap end")
    func lordHoweQuietEndInPartialGap() throws {
        // Sun Oct 4 2026: 02:00 +10:30 -> 02:30 +11:00. Quiet 01:00-02:15 ends
        // at a time that does not exist.
        let result = try Self.fire(
            "2026-10-04T01:15:00+10:30",
            quiet: TimeRange(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 2, minute: 15)),
            zone: "Australia/Lord_Howe")

        #expect(result.fire == EngineFixtures.date("2026-10-04T02:30:00+11:00"))
    }

    @Test("Los Angeles fall-back: a second-pass occurrence fires at that pass's quiet end")
    func losAngelesSecondPassOccurrenceFiresAfterItself() throws {
        // Sun Nov 1 2026: 01:00-02:00 happens twice. 01:15 PST is the second
        // pass, inside quiet 00:30-01:30.
        let result = try Self.fire(
            "2026-11-01T01:15:00-08:00",
            quiet: TimeRange(start: TimeOfDay(hour: 0, minute: 30), end: TimeOfDay(hour: 1, minute: 30)),
            zone: "America/Los_Angeles")

        #expect(result.fire == EngineFixtures.date("2026-11-01T01:30:00-08:00"))
    }

    @Test("Santiago spring-forward at midnight: an occurrence right after the gap fires at the quiet end")
    func santiagoOccurrenceAfterMidnightGap() throws {
        // Sun Sep 6 2026: 00:00 -04:00 -> 01:00 -03:00, so 00:00-01:00 does not
        // exist. Quiet 00:00-06:00 starts inside the gap.
        let result = try Self.fire(
            "2026-09-06T01:00:00-03:00",
            quiet: TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 6)),
            zone: "America/Santiago")

        #expect(result.fire == EngineFixtures.date("2026-09-06T06:00:00-03:00"))
    }

    @Test("Santiago fall-back at midnight: an occurrence in the repeated hour before midnight fires after itself")
    func santiagoOccurrenceInRepeatedHourBeforeMidnight() throws {
        // Sat Apr 4 2026: 00:00 Sun -03:00 -> 23:00 Sat -04:00, so 23:00-24:00
        // happens twice. 23:15 -04:00 is the second pass, inside quiet 22:30-23:30.
        let result = try Self.fire(
            "2026-04-04T23:15:00-04:00",
            quiet: TimeRange(start: TimeOfDay(hour: 22, minute: 30), end: TimeOfDay(hour: 23, minute: 30)),
            zone: "America/Santiago")

        #expect(result.fire == EngineFixtures.date("2026-04-04T23:30:00-04:00"))
    }

    @Test("A quiet range whose start equals its end leaves the occurrence unchanged")
    func emptyQuietRangeLeavesOccurrenceUnchanged() throws {
        let quiet = TimeRange(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 7))
        for occurrence in ["2026-06-14T07:00:00-04:00", "2026-06-14T12:00:00-04:00", "2026-06-14T03:00:00-04:00"] {
            let result = try Self.fire(occurrence, quiet: quiet, zone: "America/New_York")

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

    // MARK: - A quiet end must be a real wall-clock time outside quiet hours

    @Test("Lord Howe spring-forward: quiet 01:00-02:45 ends at the first real 02:45, never inside the gap's tail")
    func lordHoweQuietEndJustAfterTheGap() throws {
        let quiet = TimeRange(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 2, minute: 45))
        let result = try Self.fire("2026-10-04T01:15:00+10:30", quiet: quiet, zone: "Australia/Lord_Howe")

        #expect(result.fire == EngineFixtures.date("2026-10-04T02:45:00+11:00"))
        if let fire = result.fire {
            Self.expectValid(fire, occurrence: result.occurrence, quiet: quiet, zone: "Australia/Lord_Howe")
        }
    }

    @Test("Lord Howe spring-forward: a quiet end at every minute 02:30-02:59 is that real minute",
          arguments: Array(30...59))
    func lordHoweQuietEndAfterTheGapIsExact(minute: Int) throws {
        let quiet = TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 2, minute: minute))
        let result = try Self.fire("2026-10-04T01:15:00+10:30", quiet: quiet, zone: "Australia/Lord_Howe")

        let expected = "2026-10-04T02:\(String(format: "%02d", minute)):00+11:00"
        #expect(result.fire == EngineFixtures.date(expected))
        if let fire = result.fire {
            Self.expectValid(fire, occurrence: result.occurrence, quiet: quiet, zone: "Australia/Lord_Howe")
        }
    }

    @Test("Lord Howe fall-back: quiet 22:00-01:00 ends at the first 01:00, before the repeated half hour")
    func lordHoweQuietEndJustBeforeTheFold() throws {
        let quiet = TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 1))
        let result = try Self.fire("2026-04-05T00:30:00+11:00", quiet: quiet, zone: "Australia/Lord_Howe")

        #expect(result.fire == EngineFixtures.date("2026-04-05T01:00:00+11:00"))
    }

    @Test("Lord Howe fall-back: a quiet end at every minute 01:00-01:29 is that real minute",
          arguments: Array(0...29))
    func lordHoweQuietEndBeforeTheFoldIsExact(minute: Int) throws {
        let quiet = TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 1, minute: minute))
        let result = try Self.fire("2026-04-05T00:30:00+11:00", quiet: quiet, zone: "Australia/Lord_Howe")

        let expected = "2026-04-05T01:\(String(format: "%02d", minute)):00+11:00"
        #expect(result.fire == EngineFixtures.date(expected))
        if let fire = result.fire {
            Self.expectValid(fire, occurrence: result.occurrence, quiet: quiet, zone: "Australia/Lord_Howe")
        }
    }

    @Test("Nuuk: a quiet end swallowed by the 23:00 gap leaves no notification that day")
    func nuukQuietEndInsideTheGapIsDropped() throws {
        // Sat Mar 28 2026: 23:00 -02:00 -> 00:00 -01:00 (the gap runs to
        // midnight), so quiet 22:00-23:30 ends at a time that does not exist
        // and the next real instant is on the next day.
        let result = try Self.fire(
            "2026-03-28T22:15:00-02:00",
            quiet: TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 23, minute: 30)),
            zone: "America/Nuuk")

        #expect(result.fire == nil)
    }

    @Test("A wrapping quiet range that starts inside the New York gap never yields a time inside quiet hours")
    func degenerateQuietRangeStartingInTheGap() throws {
        // Sun Mar 8 2026: 02:00 -> 03:00. Quiet 02:30-02:00 covers every
        // wall-clock time that day except 02:00-02:30, which does not exist.
        let quiet = TimeRange(start: TimeOfDay(hour: 2, minute: 30), end: TimeOfDay(hour: 2))
        let first = EngineFixtures.date("2026-03-08 00:00", tz: "America/New_York")
        let last = EngineFixtures.date("2026-03-08 23:00", tz: "America/New_York")

        for occurrence in EngineFixtures.hourlyInstants(from: first, through: last) {
            let window = EngineFixtures.allDaysWindow(
                [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))],
                tz: "America/New_York", quiet: quiet)
            let zone = try #require(TimeZone(identifier: "America/New_York"))
            let fire = ReminderEngine(clock: { occurrence })
                .occasionFireDate(for: occurrence, in: window, timeZone: zone)

            if let fire {
                Self.expectValid(fire, occurrence: occurrence, quiet: quiet, zone: "America/New_York",
                                 "(occurrence \(occurrence))")
            }
        }
    }

    @Test("Los Angeles fall-back: a first-pass occurrence waits for the second 01:30 (§9 contract 1)")
    func losAngelesFirstPassOccurrenceWaitsForTheSecondQuietEnd() throws {
        // 01:15 PDT with quiet 00:30-01:30: the clock re-enters quiet at 01:00
        // PST, so quiet really ends at 01:30 PST.
        let result = try Self.fire(
            "2026-11-01T01:15:00-07:00",
            quiet: TimeRange(start: TimeOfDay(hour: 0, minute: 30), end: TimeOfDay(hour: 1, minute: 30)),
            zone: "America/Los_Angeles")

        #expect(result.fire == EngineFixtures.date("2026-11-01T01:30:00-08:00"))
    }
}
