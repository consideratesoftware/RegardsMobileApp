import Foundation
import Testing
@testable import Regards

/// The representative occasion seeds must survive DST-transition days.
///
/// `MockRepositories.seedRepresentativeStates` used to build its birthday and
/// anniversary instants with `calendar.date(bySettingHour:)` inside an
/// `if let` chain. That returns nil when the wall-clock hour does not exist,
/// so on a day whose DST gap swallows the hour the occasions were silently
/// dropped and the representative states R34 guarantees became unreachable —
/// on exactly the days most likely to expose a scheduling bug.
struct MockOccasionSeedingTests {

    @Test("A skipped wall-clock hour still yields a real same-day instant")
    func skippedWallClockHourStillSeeds() throws {
        // US Pacific springs forward 02:00 → 03:00 on 2026-03-08, so the whole
        // 2 o'clock hour is absent that day.
        //
        // Measured behavior: `date(bySettingHour:)` does not return nil here —
        // it forgives the gap and snaps forward to 03:00. The `Optional`
        // return is still real API surface, so the seeding helper handles nil
        // rather than dropping the occasion; this test pins the outcome the
        // seeds actually depend on, which is that a skipped hour still
        // produces a real instant on the right local day.
        let timezone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let transitionEve = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 7,
            hour: 12
        )))
        let startOfEve = calendar.startOfDay(for: transitionEve)
        let transitionDay = try #require(
            calendar.date(byAdding: .day, value: 1, to: startOfEve)
        )

        let seeded = try #require(MockStore.occasionInstant(
            daysAfter: startOfEve,
            offset: 1,
            hour: 2,
            calendar: calendar
        ))

        #expect(calendar.isDate(seeded, inSameDayAs: transitionDay))
        // The requested hour does not exist, so the instant must be after it.
        #expect(calendar.component(.hour, from: seeded) >= 2)
    }

    @Test("An ordinary day resolves to the exact requested hour")
    func ordinaryDayUsesTheExactHour() throws {
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let startOfToday = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 4
        )))

        let instant = try #require(MockStore.occasionInstant(
            daysAfter: startOfToday,
            offset: 1,
            hour: 9,
            calendar: calendar
        ))

        let components = calendar.dateComponents([.year, .month, .day, .hour], from: instant)
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 5)
        #expect(components.hour == 9)
    }

    @Test(
        "Both representative occasions seed across DST-transition days",
        arguments: [
            ("America/Los_Angeles", 2026, 3, 8),
            ("America/Los_Angeles", 2026, 11, 1),
            ("Australia/Lord_Howe", 2026, 4, 5),
            ("Asia/Beirut", 2026, 3, 29),
        ]
    )
    func occasionsSeedOnTransitionDays(
        zone: (id: String, year: Int, month: Int, day: Int)
    ) async throws {
        let timezone = try #require(TimeZone(identifier: zone.id))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        // Start the day before the transition so both the +1 birthday and the
        // +4 anniversary straddle it.
        let now = try #require(calendar.date(from: DateComponents(
            year: zone.year,
            month: zone.month,
            day: zone.day,
            hour: 12
        ))).addingTimeInterval(-86_400)

        let mocks = MockRepositories(now: now, window: .defaultV1(timezone: timezone))
        let pending = try await mocks.reminders.fetchAllPending()

        #expect(pending.contains { $0.kind == .birthday })
        #expect(pending.contains { $0.kind == .anniversary })
    }
}
