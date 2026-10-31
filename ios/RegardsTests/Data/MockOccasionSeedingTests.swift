import Foundation
import Testing
@testable import Regards

/// The mock's representative birthday and anniversary come from
/// `MockRepositories.occasionProvider` through `SchedulingPass` (the store seeds
/// no occasion rows), and must survive DST-transition days: a wall-clock hour
/// that does not exist must not drop the occasion, since that would make the
/// representative states R34 guarantees unreachable on exactly the days most
/// likely to expose a scheduling bug.
struct MockOccasionSeedingTests {

    @Test("The shipped fixture never puts a cadence and an occasion on one day")
    @MainActor
    func shippedFixtureHasNoSameDayDuplicate() async throws {
        // Upcoming computes its cadence rows itself until TF-07f, so a seeded
        // cadence or occasion offset that lands both on one day would double
        // a row in every screenshot and demo. This pins the shipped fixture.
        // The shipped window, not a UTC stand-in: guarding the fixture means
        // guarding it under the timezone the app actually boots with.
        let window = MockRepositories.defaultWindow
        let timezone = window.timeZone
        let now = MockRepositories.defaultNow
        let mocks = MockRepositories(now: now, window: window)
        let scheduler = mocks.occasionPass(now: now, window: window)
        try await scheduler.runFull()
        let viewModel = UpcomingViewModel(
            contacts: mocks.contacts,
            reminders: mocks.reminders,
            scheduler: scheduler,
            interactions: mocks.interactions,
            window: window,
            clock: { now }
        )

        await viewModel.load()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        var seen: Set<String> = []
        let rows = viewModel.groups.flatMap(\.rows)
        #expect(rows.contains { $0.kind == .birthday } && rows.contains { $0.kind == .anniversary })
        for row in rows {
            let day = calendar.startOfDay(for: row.scheduledFor)
            let key = "\(row.contactId.uuidString)-\(day.timeIntervalSince1970)"
            #expect(seen.insert(key).inserted, "duplicate same-day row for \(row.name)")
        }
    }

    @Test("The store seeds no occasion rows; the pass writes the representative birthday and anniversary")
    func representativeOccasionState() async throws {
        let now = MockRepositories.defaultNow
        let mocks = MockRepositories(now: now)
        #expect(try await mocks.reminders.fetchAllPending().isEmpty)

        try await mocks.occasionPass(now: now).runFull()

        let occasions = try await mocks.reminders.fetchAllPending().filter { $0.kind != .cadence }
        #expect(Set(occasions.map(\.kind)) == [.birthday, .anniversary])
        #expect(occasions.allSatisfy { $0.state == .pending })
    }

    @Test("Occasion rows the pass writes for the seed cast use the §9 contract-5 identity")
    func seededOccasionIdentitiesMatchTheScheme() async throws {
        // TF-07's reconcile and orphan-cancellation logic keys on
        // "contact-{uuid}-{kind}"; a mock-only "mock-birthday-{uuid}" shape
        // would drift from what that logic expects to find.
        let now = MockRepositories.defaultNow
        let mocks = MockRepositories(now: now)
        try await mocks.occasionPass(now: now).runFull()

        let occasions = try await mocks.reminders.fetchAllPending().filter { $0.kind != .cadence }

        #expect(Set(occasions.map(\.kind)) == [.birthday, .anniversary])
        for reminder in occasions {
            let expected = "contact-\(reminder.contactId.uuidString)-\(reminder.kind.rawValue)"
            #expect(reminder.osNotificationId == expected)
        }
    }

    @Test(
        "Both representative occasions get rows across DST-transition days",
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

        let window = ReminderWindow.defaultV1(timezone: timezone)
        let mocks = MockRepositories(now: now, window: window)
        try await mocks.occasionPass(now: now, window: window).runFull()
        let pending = try await mocks.reminders.fetchAllPending()

        #expect(pending.contains { $0.kind == .birthday })
        #expect(pending.contains { $0.kind == .anniversary })
    }
}
