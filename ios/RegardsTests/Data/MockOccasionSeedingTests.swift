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

    @Test("An unmaterializable hour falls back to the day rather than nil")
    func unmaterializableHourFallsBackToTheDay() throws {
        // Forces the branch a DST gap turned out not to reach:
        // `date(bySettingHour:)` returns nil for an hour no calendar can
        // materialize, and `nextDate(matching:)` cannot find one either, so
        // the terminal `?? day` fallback is what keeps the seed alive. The
        // point is not hour 25 specifically — it is that no input makes this
        // helper return nil and silently drop a representative occasion.
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let startOfToday = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 4
        )))
        let expectedDay = try #require(
            calendar.date(byAdding: .day, value: 1, to: startOfToday)
        )

        #expect(calendar.date(bySettingHour: 25, minute: 0, second: 0, of: expectedDay) == nil)

        let seeded = try #require(MockStore.occasionInstant(
            daysAfter: startOfToday,
            offset: 1,
            hour: 25,
            calendar: calendar
        ))

        #expect(seeded == expectedDay)
    }

    @Test(
        "The helper never returns nil for a plausible seed offset",
        arguments: [-30, -1, 0, 1, 4, 30, 366]
    )
    func helperNeverReturnsNilForSeedOffsets(offset: Int) throws {
        // The seeding calls this for a handful of small offsets. Whatever the
        // fallback chain does internally, the contract the seeds rely on is
        // that it always yields an instant — a nil here is how the
        // representative occasions used to vanish without a failure.
        let timezone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let startOfToday = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 7
        )))

        #expect(MockStore.occasionInstant(
            daysAfter: startOfToday,
            offset: offset,
            hour: 9,
            calendar: calendar
        ) != nil)
    }

    @Test("The shipped fixture never puts a cadence and an occasion on one day")
    @MainActor
    func shippedFixtureHasNoSameDayDuplicate() async throws {
        // §9 contract 6 is unenforced in UpcomingViewModel until TF-07, so the
        // shipped mock build must not create the duplicate itself. A future
        // edit to a seeded cadence or occasion offset could silently
        // reintroduce a doubled row in every screenshot and demo; this pins it.
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        let now = MockRepositories.defaultNow
        let mocks = MockRepositories(now: now, window: .defaultV1(timezone: timezone))
        let viewModel = UpcomingViewModel(
            contacts: mocks.contacts,
            reminders: mocks.reminders,
            window: .defaultV1(timezone: timezone),
            clock: { now }
        )

        await viewModel.load()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        var seen: Set<String> = []
        for row in viewModel.groups.flatMap(\.rows) {
            let day = calendar.startOfDay(for: row.scheduledFor)
            let key = "\(row.contactId.uuidString)-\(day.timeIntervalSince1970)"
            #expect(seen.insert(key).inserted, "duplicate same-day row for \(row.name)")
        }
    }

    @Test("Seeded occasion notification ids use the §9 contract-5 identity")
    func seededOccasionIdentitiesMatchTheScheme() async throws {
        // TF-07's reconcile and orphan-cancellation logic keys on
        // "contact-{uuid}-{kind}"; a mock-only "mock-birthday-{uuid}" shape
        // would drift from what that logic expects to find.
        let mocks = MockRepositories(now: MockRepositories.defaultNow)
        let pending = try await mocks.reminders.fetchAllPending()

        for reminder in pending where reminder.kind != .cadence {
            let expected = "contact-\(reminder.contactId.uuidString)-\(reminder.kind.rawValue)"
            #expect(reminder.osNotificationId == expected)
        }
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
