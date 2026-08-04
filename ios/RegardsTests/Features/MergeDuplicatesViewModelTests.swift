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
    // MARK: - Fixtures

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

    private static let classificationContacts = [
        Contact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            systemContactRef: "merge-phone-a",
            displayName: "Phone Alpha",
            preferredChannel: .signal,
            preferredChannelValue: "+14155550101"
        ),
        Contact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            systemContactRef: "merge-phone-b",
            displayName: "Phone Beta",
            preferredChannel: .phoneCall,
            preferredChannelValue: "+1 415 555 0101"
        ),
        Contact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            systemContactRef: "merge-email-a",
            displayName: "Email Alpha",
            preferredChannel: .email,
            preferredChannelValue: "shared@example.com"
        ),
        Contact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
            systemContactRef: "merge-email-b",
            displayName: "Email Beta",
            preferredChannel: .email,
            preferredChannelValue: "SHARED@example.com"
        ),
        Contact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
            systemContactRef: "merge-name-a",
            displayName: "Name Only Match",
            preferredChannel: .phoneCall,
            preferredChannelValue: ""
        ),
        Contact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000016")!,
            systemContactRef: "merge-name-b",
            displayName: "Name Only Match",
            preferredChannel: .email,
            preferredChannelValue: ""
        ),
    ]

    // MARK: - Candidate mapping and mutations

    @Test("Load classifies candidate values and defaults selection by confidence")
    func loadClassifiesCandidatesAndDefaultsSelection() async {
        let repository = MergeDuplicatesTestContactRepository(steps: [
            .success(Self.classificationContacts),
        ])
        let viewModel = MergeDuplicatesViewModel(contacts: repository)

        await viewModel.load()

        let high = viewModel.candidates.first { $0.confidence == .high }
        let medium = viewModel.candidates.first { $0.confidence == .medium }
        let low = viewModel.candidates.first { $0.confidence == .low }
        #expect(viewModel.candidates.count == 3)
        #expect(high?.isSelected == true)
        #expect(high?.a.phone != nil)
        #expect(high?.b.phone != nil)
        #expect(high?.a.email == nil)
        #expect(high?.b.email == nil)
        #expect(medium?.isSelected == false)
        #expect(medium?.a.email != nil)
        #expect(medium?.b.email != nil)
        #expect(medium?.a.phone == nil)
        #expect(medium?.b.phone == nil)
        #expect(low?.isSelected == false)
        #expect(low?.a.displayName == "Name Only Match")
        #expect(low?.b.displayName == "Name Only Match")
        #expect(low?.a.phone == nil)
        #expect(low?.b.phone == nil)
        #expect(low?.a.email == nil)
        #expect(low?.b.email == nil)
    }

    @Test("Selection and primary mutations update only the matching candidate")
    func candidateMutationsUpdateMatchingState() async {
        let repository = MergeDuplicatesTestContactRepository(steps: [
            .success(Self.classificationContacts),
        ])
        let viewModel = MergeDuplicatesViewModel(contacts: repository)

        await viewModel.load()
        guard let candidate = viewModel.candidates.first else {
            Issue.record("Expected duplicate candidates")
            return
        }
        let untouchedID = viewModel.candidates.last?.id
        let untouchedBefore = viewModel.candidates.last

        viewModel.toggleSelection(for: candidate.id)
        viewModel.setPrimary(for: candidate.id, isA: false)

        let updated = viewModel.candidates.first { $0.id == candidate.id }
        #expect(updated?.isSelected == !candidate.isSelected)
        #expect(updated?.primaryIsA == false)
        #expect(viewModel.candidates.first { $0.id == untouchedID } == untouchedBefore)
    }

    @Test("Archived contacts are excluded from duplicate candidates")
    func archivedContactsAreExcluded() async {
        let active = Self.duplicateContacts[0]
        var archived = Self.duplicateContacts[1]
        archived.archivedAt = Date()
        let repository = MergeDuplicatesTestContactRepository(steps: [
            .success([active, archived]),
        ])
        let viewModel = MergeDuplicatesViewModel(contacts: repository)

        await viewModel.load()

        #expect(viewModel.candidates.isEmpty)
    }

    @Test("Members of the same virtual group are excluded")
    func sameGroupContactsAreExcluded() async {
        let groupID = UUID()
        var groupedPrimary = Self.duplicateContacts[0]
        var groupedMember = Self.duplicateContacts[1]
        groupedPrimary.contactGroupId = groupID
        groupedMember.contactGroupId = groupID
        let repository = MergeDuplicatesTestContactRepository(steps: [
            .success([groupedPrimary, groupedMember]),
        ])
        let viewModel = MergeDuplicatesViewModel(contacts: repository)

        await viewModel.load()

        #expect(viewModel.candidates.isEmpty)
    }

    @Test("One grouped contact remains eligible against an ungrouped duplicate")
    func asymmetricGroupMembershipRemainsEligible() async {
        var grouped = Self.duplicateContacts[0]
        grouped.contactGroupId = UUID()
        let repository = MergeDuplicatesTestContactRepository(steps: [
            .success([grouped, Self.duplicateContacts[1]]),
        ])
        let viewModel = MergeDuplicatesViewModel(contacts: repository)

        await viewModel.load()

        #expect(viewModel.candidates.count == 1)
    }

    @Test("Contacts in different virtual groups remain eligible")
    func differentGroupContactsRemainEligible() async {
        var first = Self.duplicateContacts[0]
        var second = Self.duplicateContacts[1]
        first.contactGroupId = UUID()
        second.contactGroupId = UUID()
        let repository = MergeDuplicatesTestContactRepository(steps: [
            .success([first, second]),
        ])
        let viewModel = MergeDuplicatesViewModel(contacts: repository)

        await viewModel.load()

        #expect(viewModel.candidates.count == 1)
    }

    // MARK: - Loading lifecycle

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
        #expect(viewModel.loadState == .failed)
        #expect(viewModel.candidates.isEmpty)

        await viewModel.load()

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.candidates.count == 1)
        let requestCount = await repository.requestCount()
        #expect(requestCount == 2)
    }
}
