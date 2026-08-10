import Foundation
import Testing
@testable import Regards

/// "Caught up" persistence and cross-screen live updates for
/// `OverdueViewModel` (ARCHITECTURE.md §14 PR22). `OverdueViewModelTests`
/// owns the pure `makeOverdueRow` day-math suite; this file owns the async
/// action and `observeTracked()` behavior.
@MainActor
struct OverdueViewModelActionTests {

    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func overdueContact(
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

    /// A fresh `OverdueViewModel` with independent `StubReminderRepository`/
    /// `SchedulingPass` instances (tests that need to observe a snooze's
    /// write-through construct their own `reminders` and pass it to both).
    static func viewModel(
        contacts: StubContactRepository,
        interactions: any InteractionRepository = StubInteractionRepository(),
        reminders: StubReminderRepository = StubReminderRepository(),
        clock: @escaping @Sendable () -> Date = { Self.now }
    ) -> OverdueViewModel {
        OverdueViewModel(
            contacts: contacts,
            interactions: interactions,
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: clock),
            clock: clock
        )
    }

    @Test("Caught up removes the row instantly and persists the interaction")
    func markCaughtUpRemovesRowAndPersists() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let viewModel = Self.viewModel(contacts: contacts, interactions: interactions)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.markCaughtUp(contactId: contact.id)

        #expect(viewModel.rows.isEmpty)
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == Self.now)
    }

    @Test("A failing caught-up write reloads to restore the true state")
    func markCaughtUpFailureReloads() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository.failing()
        let viewModel = Self.viewModel(contacts: contacts, interactions: interactions)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.markCaughtUp(contactId: contact.id)

        // The write failed, so a fresh load restores the still-overdue row
        // rather than leaving the optimistic removal standing.
        #expect(viewModel.rows.map(\.contactId) == [contact.id])
    }

    @Test("A write on the same repository through a different reference is reflected live")
    func liveUpdateReflectsWriteFromAnotherReference() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = Self.viewModel(contacts: contacts)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        // Simulates Contact Detail's ContactDetailViewModel, holding its own
        // reference to the same repository, marking the contact caught up.
        var updated = contact
        updated.lastInteractedAt = Self.now
        try await contacts.upsert(updated)

        // The write reaches Overdue through `observeTracked()`'s subscriber
        // Task, not a call this test itself awaits — `waitUntil` yields
        // cooperatively until it drains rather than sleeping a fixed delay.
        let sawEmpty = await waitUntil { viewModel.rows.isEmpty }
        #expect(sawEmpty)
    }

    // MARK: - Snooze (§14 PR22 SchedulingPass stub)

    @Test("Snooze removes the row instantly and writes a pending cadence reminder 7 days out")
    func snoozeRemovesRowAndWritesReminder() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let viewModel = Self.viewModel(contacts: contacts, interactions: interactions, reminders: reminders)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.snooze(contactId: contact.id)

        #expect(viewModel.rows.isEmpty)
        #expect(await interactions.appendedLogs().isEmpty) // decision #31: no interaction logged
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == contact.lastInteractedAt) // decision #31: untouched
        let pending = try await reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].kind == .cadence)
        #expect(pending[0].scheduledFor == Self.now.addingTimeInterval(7 * 86_400))
    }

    @Test("A snoozed contact's row leaves Overdue and returns once the snooze lapses")
    func snoozedRowReturnsAfterSevenDays() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let clock = MutableClock(Self.now)
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: StubInteractionRepository(),
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: clock.now),
            clock: clock.now
        )
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.snooze(contactId: contact.id)
        #expect(viewModel.rows.isEmpty)

        // Still within the snoozed week: a fresh load keeps the row hidden.
        clock.advance(by: 6 * 86_400)
        await viewModel.load()
        #expect(viewModel.rows.isEmpty)

        // Past the snoozed week: the row returns, computed via the ordinary
        // lastInteractedAt-based path (now far more than 7 days overdue).
        clock.advance(by: 2 * 86_400)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])
    }

    @Test("A second snooze re-pushes 7 days from its own call, not stacked on the first")
    func secondSnoozeRePushesFromNow() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let clock = MutableClock(Self.now)
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: StubInteractionRepository(),
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: clock.now),
            clock: clock.now
        )
        await viewModel.load()

        await viewModel.snooze(contactId: contact.id)
        clock.advance(by: 3 * 86_400)
        await viewModel.snooze(contactId: contact.id)

        let pending = try await reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1) // idempotent write-through: still one row, not two
        #expect(pending[0].scheduledFor == clock.now().addingTimeInterval(7 * 86_400))
    }
}
