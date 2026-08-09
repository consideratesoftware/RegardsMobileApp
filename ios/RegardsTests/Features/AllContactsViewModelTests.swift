import Foundation
import Testing
@testable import Regards

@MainActor
struct AllContactsViewModelTests {
    @Test("All Contacts exposes tracked and untracked active imports")
    func loadIncludesEveryActiveContactWithoutTrackingWrites() async throws {
        let trackedID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let untrackedID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let archivedID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let tracked = Self.contact(
            id: trackedID,
            name: "Tracked",
            tracked: true
        )
        let untracked = Self.contact(
            id: untrackedID,
            name: "Imported",
            tracked: false
        )
        let archived = Self.contact(
            id: archivedID,
            name: "Archived",
            tracked: true,
            archivedAt: Self.now
        )
        let repository = RecordingAllContactsRepository([tracked, untracked, archived])
        let viewModel = AllContactsViewModel(contacts: repository, clock: { Self.now })

        await viewModel.load()

        #expect(viewModel.loadState == .loaded)
        #expect(Set(viewModel.contacts.map(\.id)) == Set([tracked.id, untracked.id]))
        #expect(viewModel.contacts.first { $0.id == untracked.id }?.tracked == false)
        #expect(viewModel.summary == "2 contacts")
        #expect(await repository.readCounts() == .init(all: 1, tracked: 0))
        #expect(await repository.writeCount() == 0)
    }

    @Test("Search includes an untracked imported contact")
    func searchIncludesUntrackedImport() async {
        let imported = Self.contact(
            id: UUID(),
            name: "Leia Organa",
            tracked: false
        )
        let repository = RecordingAllContactsRepository([imported])
        let viewModel = AllContactsViewModel(contacts: repository, clock: { Self.now })

        await viewModel.load()

        #expect(viewModel.filtered(searchText: "ORG") == [imported])
        #expect(viewModel.summary == "1 contact")
    }

    @Test("All Contacts sorts by priority, name, then identifier")
    func loadUsesStableUserVisibleOrdering() async throws {
        let close = Self.contact(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004")),
            name: "Zeta Close",
            tracked: false,
            priority: .close
        )
        let alphaSecond = Self.contact(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
            name: "alpha",
            tracked: false
        )
        let beta = Self.contact(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
            name: "Beta",
            tracked: false
        )
        let alphaFirst = Self.contact(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            name: "Alpha",
            tracked: false
        )
        let repository = RecordingAllContactsRepository([
            beta, alphaSecond, close, alphaFirst,
        ])
        let viewModel = AllContactsViewModel(contacts: repository, clock: { Self.now })

        await viewModel.load()

        #expect(viewModel.contacts.map(\.id) == [
            close.id, alphaFirst.id, alphaSecond.id, beta.id,
        ])
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func contact(
        id: UUID,
        name: String,
        tracked: Bool,
        priority: PriorityTier = .regular,
        archivedAt: Date? = nil
    ) -> Contact {
        Contact(
            id: id,
            systemContactRef: "system-\(id.uuidString)",
            displayName: name,
            tracked: tracked,
            priorityTier: priority,
            archivedAt: archivedAt
        )
    }
}

private actor RecordingAllContactsRepository: ContactRepository {
    struct ReadCounts: Equatable {
        let all: Int
        let tracked: Int
    }

    private var contacts: [Contact]
    private var allReadCount = 0
    private var trackedReadCount = 0
    private var writes = 0

    init(_ contacts: [Contact]) {
        self.contacts = contacts
    }

    func fetchAll() async throws -> [Contact] {
        allReadCount += 1
        return contacts
    }

    func fetchTracked() async throws -> [Contact] {
        trackedReadCount += 1
        return contacts.filter { $0.tracked && $0.isActive }
    }

    func fetch(id: UUID) async throws -> Contact? {
        contacts.first { $0.id == id }
    }

    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        contacts.filter { $0.contactGroupId == groupId }
    }

    func upsert(_ contact: Contact) async throws {
        writes += 1
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
    }

    func archive(id: UUID, at: Date) async throws {
        writes += 1
    }

    func readCounts() -> ReadCounts {
        ReadCounts(all: allReadCount, tracked: trackedReadCount)
    }

    func writeCount() -> Int {
        writes
    }
}
