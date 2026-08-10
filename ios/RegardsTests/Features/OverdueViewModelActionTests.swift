import Foundation
import Testing
@testable import Regards

/// "Caught up" persistence and cross-screen live updates for
/// `OverdueViewModel` (ARCHITECTURE.md §14 PR22). `OverdueViewModelTests`
/// owns the pure `makeOverdueRow` day-math suite; this file owns the async
/// action and `observeTracked()` behavior.
@MainActor
struct OverdueViewModelActionTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

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

    @Test("Caught up removes the row instantly and persists the interaction")
    func markCaughtUpRemovesRowAndPersists() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let viewModel = OverdueViewModel(contacts: contacts, interactions: interactions, clock: { Self.now })
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
        let viewModel = OverdueViewModel(contacts: contacts, interactions: interactions, clock: { Self.now })
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
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: StubInteractionRepository(),
            clock: { Self.now }
        )
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
}
