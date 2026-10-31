import Foundation
import Testing
@testable import Regards

/// `ReminderEngine.occasionFireDate` in zones where Foundation resolves a
/// wall-clock time to the wrong instant (R63). The Chatham gap and the Lord Howe
/// pre-fold case are fixed in the engine; the Havana and Troll cases pin an
/// accepted residual, so a change to them is a decision, not an accident.
/// Shares `OccasionFireDateDSTTests.fire`, which builds the window and the
/// zone the way SchedulingPass does.
struct OccasionFireDateTransitionPinTests {

    private static func quiet(_ startHour: Int, _ startMinute: Int, _ endHour: Int, _ endMinute: Int) -> TimeRange {
        TimeRange(start: TimeOfDay(hour: startHour, minute: startMinute),
                  end: TimeOfDay(hour: endHour, minute: endMinute))
    }

    // MARK: - Fixed: Pacific/Chatham spring-forward

    /// Sun Sep 27 2026: 02:45 +12:45 -> 03:45 +13:45, so 02:45-03:45 does not
    /// exist. A quiet end inside it is replaced by the gap end. Foundation's
    /// `.nextTime` answers 04:00 there, which the engine rejected, so the
    /// occasion lost its notification.
    @Test("Chatham spring-forward: a quiet end inside the 1-hour gap fires at the gap end",
          arguments: [0, 15, 30, 44])
    func chathamQuietEndInTheGapFiresAtTheGapEnd(quietEndMinute: Int) throws {
        let quiet = Self.quiet(1, 0, 3, quietEndMinute)
        let result = try OccasionFireDateDSTTests.fire(
            "2026-09-27T01:30:00+12:45", quiet: quiet, zone: "Pacific/Chatham")

        #expect(result.fire == EngineFixtures.date("2026-09-27T03:45:00+13:45"))
        if let fire = result.fire {
            OccasionFireDateDSTTests.expectValid(
                fire, occurrence: result.occurrence, quiet: quiet, zone: "Pacific/Chatham")
        }
    }

    @Test("Chatham spring-forward: a quiet end at the gap end fires at that real time")
    func chathamQuietEndAtTheGapEnd() throws {
        let result = try OccasionFireDateDSTTests.fire(
            "2026-09-27T01:30:00+12:45", quiet: Self.quiet(1, 0, 3, 45), zone: "Pacific/Chatham")

        #expect(result.fire == EngineFixtures.date("2026-09-27T03:45:00+13:45"))
    }

    // MARK: - Pacific/Chatham fall-back

    /// Sun Apr 5 2026: 03:45 +13:45 -> 02:45 +12:45, so 02:45-03:45 happens
    /// twice. Quiet 02:00-03:00 is re-entered at the second 02:45, so it
    /// really ends at the second 03:00.
    @Test("Chatham fall-back: an occurrence in either pass waits for the second quiet end",
          arguments: ["2026-04-05T02:50:00+13:45", "2026-04-05T02:50:00+12:45"])
    func chathamFoldOccurrenceWaitsForTheSecondQuietEnd(occurrence: String) throws {
        let result = try OccasionFireDateDSTTests.fire(
            occurrence, quiet: Self.quiet(2, 0, 3, 0), zone: "Pacific/Chatham")

        #expect(result.fire == EngineFixtures.date("2026-04-05T03:00:00+12:45"))
    }

    // MARK: - Fixed: Lord Howe, occurrence before the fold

    /// Sun Apr 5 2026: 02:00 +11:00 -> 01:30 +10:30. Quiet 22:00-01:45 ends
    /// at 01:45 +11:00, but the clock then reads 01:30 +10:30, inside quiet
    /// again, so quiet really ends at 01:45 +10:30 (§9 contract 1, the same
    /// rule as the Los Angeles case in `OccasionFireDateDSTTests`).
    @Test("Lord Howe fall-back: an occurrence before the fold waits for the second quiet end")
    func lordHoweOccurrenceBeforeTheFoldWaitsForTheSecondQuietEnd() throws {
        let result = try OccasionFireDateDSTTests.fire(
            "2026-04-05T01:15:00+11:00", quiet: Self.quiet(22, 0, 1, 45), zone: "Australia/Lord_Howe")

        #expect(result.fire == EngineFixtures.date("2026-04-05T01:45:00+10:30"))
    }

    // MARK: - Accepted residuals (R63)

    /// Sun Nov 1 2026: 01:00 -04:00 -> 00:00 -05:00, so 00:00-01:00 happens
    /// twice. Quiet 00:05-00:00 allows 00:00-00:04 -05:00, but the engine's
    /// wrapping-quiet shortcut returns no notification for a 00:10 -04:00
    /// occurrence. A skipped notification, never one inside quiet hours.
    @Test("R63 residual, Havana fall-back: a wrapping quiet range in the fold skips the notification")
    func havanaWrappingQuietInTheFoldSkipsTheNotification() throws {
        let result = try OccasionFireDateDSTTests.fire(
            "2026-11-01T00:10:00-04:00", quiet: Self.quiet(0, 5, 0, 0), zone: "America/Havana")

        #expect(result.fire == nil)
    }

    /// Sun Oct 25 2026: 03:00 +02:00 -> 01:00 +00:00, so 01:00-03:00 happens
    /// twice. Foundation's `.last` returns the first pass for Troll, so an
    /// occurrence in the first pass fires at the first pass's quiet end
    /// although the clock re-enters quiet at 02:00 +00:00. The second pass is
    /// exact.
    @Test("R63 residual, Antarctica/Troll fall-back: a first-pass occurrence fires at the first pass's quiet end")
    func trollFirstPassOccurrenceFiresAtTheFirstPassQuietEnd() throws {
        let result = try OccasionFireDateDSTTests.fire(
            "2026-10-25T02:30:00+02:00", quiet: Self.quiet(2, 0, 2, 45), zone: "Antarctica/Troll")

        #expect(result.fire == EngineFixtures.date("2026-10-25T02:45:00+02:00"))
    }

    @Test("Antarctica/Troll fall-back: a second-pass occurrence fires at the second pass's quiet end")
    func trollSecondPassOccurrenceFiresAtTheSecondPassQuietEnd() throws {
        let result = try OccasionFireDateDSTTests.fire(
            "2026-10-25T02:30:00+00:00", quiet: Self.quiet(2, 0, 2, 45), zone: "Antarctica/Troll")

        #expect(result.fire == EngineFixtures.date("2026-10-25T02:45:00+00:00"))
    }
}
