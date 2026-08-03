import Foundation
import Testing
@testable import Regards

private actor MergeDuplicatesTestContactRepository: ContactRepository {
    enum Step: Sendable {
        case success([Contact])
        case failure
    }

    enum TestError: Error {
        case unavailable
    }

    private var steps: [Step]
    private var requests = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func fetchAll() async throws -> [Contact] {
        try await fetchTracked()
    }

    func fetchTracked() async throws -> [Contact] {
        requests += 1
        guard !steps.isEmpty else { return [] }
        switch steps.removeFirst() {
        case let .success(contacts):
            return contacts
        case .failure:
            throw TestError.unavailable
        }
    }

    func requestCount() -> Int {
        requests
    }

    func fetch(id: UUID) async throws -> Contact? { nil }

    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] { [] }

    func upsert(_ contact: Contact) async throws {}

    func archive(id: UUID, at: Date) async throws {}
}

@MainActor
struct MergeDuplicatesViewModelTests {
    private static let duplicateContacts = [
        Contact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            systemContactRef: "merge-test-a",
            displayName: "Luke Skywalker",
            preferredChannel: .signal,
            preferredChannelValue: "+14155550198"
        ),
        Contact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            systemContactRef: "merge-test-b",
            displayName: "Luke Skywalker",
            preferredChannel: .signal,
            preferredChannelValue: "+1 415 555 0198"
        ),
    ]

    @Test("A repeated load preserves in-progress duplicate choices")
    func repeatedLoadPreservesChoices() async {
        let repository = MergeDuplicatesTestContactRepository(steps: [
            .success(Self.duplicateContacts),
        ])
        let viewModel = MergeDuplicatesViewModel(contacts: repository)

        await viewModel.load()
        guard let candidate = viewModel.candidates.first else {
            Issue.record("Expected one duplicate candidate")
            return
        }
        viewModel.toggleSelection(for: candidate.id)
        viewModel.setPrimary(for: candidate.id, isA: false)

        await viewModel.load()

        #expect(viewModel.candidates.first?.isSelected == false)
        #expect(viewModel.candidates.first?.primaryIsA == false)
        let requestCount = await repository.requestCount()
        #expect(requestCount == 1)
    }

    @Test("A failed initial load can retry successfully")
    func failedInitialLoadCanRetry() async {
        let repository = MergeDuplicatesTestContactRepository(steps: [
            .failure,
            .success(Self.duplicateContacts),
        ])
        let viewModel = MergeDuplicatesViewModel(contacts: repository)

        await viewModel.load()
        #expect(viewModel.candidates.isEmpty)

        await viewModel.load()

        #expect(viewModel.candidates.count == 1)
        let requestCount = await repository.requestCount()
        #expect(requestCount == 2)
    }
}
