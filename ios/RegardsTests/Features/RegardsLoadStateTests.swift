import Foundation
import Testing
@testable import Regards

private actor ScriptedContactRepository: ContactRepository {
    enum Step: Sendable {
        case success([Contact])
        case failure
    }

    enum TestError: Error {
        case unavailable
    }

    private var steps: [Step]

    init(steps: [Step]) {
        self.steps = steps
    }

    func fetchAll() async throws -> [Contact] {
        try await fetchTracked()
    }

    func fetchTracked() async throws -> [Contact] {
        guard !steps.isEmpty else { return [] }
        switch steps.removeFirst() {
        case let .success(contacts):
            return contacts
        case .failure:
            throw TestError.unavailable
        }
    }

    func fetch(id: UUID) async throws -> Contact? {
        nil
    }

    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        []
    }

    func upsert(_ contact: Contact) async throws {}

    func archive(id: UUID, at: Date) async throws {}
}

@MainActor
struct RegardsLoadStateTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func overdueContact() -> Contact {
        Contact(
            systemContactRef: "load-state-contact",
            displayName: "Alex Chen",
            tracked: true,
            cadenceDays: 1,
            priorityTier: .close,
            preferredChannel: .signal,
            preferredChannelValue: "+14155550198",
            lastInteractedAt: now.addingTimeInterval(-3 * 86_400)
        )
    }

    @Test("Overdue clears failed data and a retry can recover")
    func overdueFailureAndRetry() async {
        let repository = ScriptedContactRepository(steps: [
            .success([Self.overdueContact()]),
            .failure,
            .success([]),
        ])
        let viewModel = OverdueViewModel(
            contacts: repository,
            clock: { Self.now }
        )

        #expect(viewModel.loadState == .loading)
        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.rows.count == 1)

        await viewModel.load()
        #expect(viewModel.loadState == .failed)
        #expect(viewModel.rows.isEmpty)

        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.rows.isEmpty)
    }

    @Test("Upcoming clears failed data and a retry can recover")
    func upcomingFailureAndRetry() async {
        let repository = ScriptedContactRepository(steps: [
            .success([Self.overdueContact()]),
            .failure,
            .success([]),
        ])
        let viewModel = UpcomingViewModel(
            contacts: repository,
            clock: { Self.now }
        )

        #expect(viewModel.loadState == .loading)
        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.totalCount == 1)
        #expect(viewModel.groups.count == 1)

        await viewModel.load()
        #expect(viewModel.loadState == .failed)
        #expect(viewModel.totalCount == 0)
        #expect(viewModel.groups.isEmpty)

        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.totalCount == 0)
        #expect(viewModel.groups.isEmpty)
    }

    @Test("Contacts clears failed data and a retry can recover")
    func contactsFailureAndRetry() async {
        let repository = ScriptedContactRepository(steps: [
            .success([Self.overdueContact()]),
            .failure,
            .success([]),
        ])
        let viewModel = AllContactsViewModel(
            contacts: repository,
            clock: { Self.now }
        )

        #expect(viewModel.loadState == .loading)
        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.contacts.count == 1)
        #expect(viewModel.summary == "1 tracked")

        await viewModel.load()
        #expect(viewModel.loadState == .failed)
        #expect(viewModel.contacts.isEmpty)
        #expect(viewModel.summary == "Unavailable")

        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.contacts.isEmpty)
        #expect(viewModel.summary == "0 tracked")
    }
}
