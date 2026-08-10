import Foundation
import Testing
@testable import Regards

/// "Mark caught up" persistence and cross-screen live updates for
/// `UpcomingViewModel` (ARCHITECTURE.md §14 PR22). The boundary/duplicate/
/// state suites own load-path derivation; this file owns the async action
/// and `observeTracked()` behavior.
@MainActor
struct UpcomingViewModelActionTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func contact(
        id: UUID = UUID(),
        cadenceDays: Int = 7,
        lastInteractedAt: Date
    ) -> Contact {
        Contact(
            id: id,
            systemContactRef: "sys-\(id.uuidString)",
            displayName: "Leia Organa",
            tracked: true,
            cadenceDays: cadenceDays,
            priorityTier: .close,
            preferredChannel: .whatsapp,
            preferredChannelValue: "+14155550140",
            lastInteractedAt: lastInteractedAt
        )
    }

    @Test("Caught up removes every row for the contact instantly and persists the interaction")
    func markCaughtUpRemovesRowsAndPersists() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            interactions: interactions,
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.totalCount == 1)

        await viewModel.markCaughtUp(contactId: contact.id)

        #expect(viewModel.totalCount == 0)
        #expect(viewModel.groups.isEmpty)
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == Self.now)
    }

    @Test("A failing caught-up write reloads to restore the true state")
    func markCaughtUpFailureReloads() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            interactions: StubInteractionRepository.failing(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.totalCount == 1)

        await viewModel.markCaughtUp(contactId: contact.id)

        #expect(viewModel.totalCount == 1)
    }

    @Test("A write on the same repository through a different reference is reflected live")
    func liveUpdateReflectsWriteFromAnotherReference() async throws {
        // A horizon *shorter* than the cadence, deliberately: with the
        // default 14-day horizon, pushing `lastInteractedAt` to `now` still
        // leaves the next cadence due date (now + 7d, cadenceDays: 7) inside
        // the horizon, so the row would correctly persist with a new date —
        // not disappear. A 5-day horizon makes "now + 7d" fall outside it, so
        // the write's effect is genuinely "the row leaves Upcoming," matching
        // what this test asserts.
        let window = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 23, minute: 59))],
            timezoneIdentifier: UpcomingFixtures.utc.identifier,
            digestHorizonDays: 5
        )
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            interactions: StubInteractionRepository(),
            window: window,
            clock: { Self.now }
        )
        await viewModel.load()
        // Pre-write: 10 days since last contact, cadence 7 → 3 days overdue,
        // due date is effectively `now` → inside the 5-day horizon.
        #expect(viewModel.totalCount == 1)

        // Simulates Contact Detail marking the contact caught up through its
        // own reference to the same repository. Post-write due date is
        // `now + 7d`, outside the 5-day horizon.
        var updated = contact
        updated.lastInteractedAt = Self.now
        try await contacts.upsert(updated)

        // The write reaches Upcoming through `observeTracked()`'s subscriber
        // Task, not a call this test itself awaits — `waitUntil` yields
        // cooperatively until it drains rather than sleeping a fixed delay.
        let sawZero = await waitUntil { viewModel.totalCount == 0 }
        #expect(sawZero)
    }
}
