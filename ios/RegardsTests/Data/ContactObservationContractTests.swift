import Foundation
import Testing
@testable import Regards

/// `observeTracked()` mock/GRDB contract parity (ARCHITECTURE.md §14 PR22 —
/// "lists update live via observation"). Split from `RepositoriesTests.swift`
/// to stay under the file-length limit; shares that file's
/// `RepositoryContractBackend` / `contractContact` / `contractUUID` helpers.
struct ContactObservationContractTests {

    @Test(
        "observeTracked never replays on subscribe, then emits after a write changes the set",
        arguments: RepositoryContractBackend.allCases
    )
    func observeTrackedEmitsOnWrite(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let stream = await repositories.contacts.observeTracked()
        var iterator = stream.makeAsyncIterator()

        let observed = contractContact(id: try contractUUID(131), suffix: "observed", tracked: true)
        try await repositories.contacts.upsert(observed)

        // The first value the subscriber ever sees is the post-write set —
        // never an eager replay of whatever was current at subscribe time
        // (that would race a caller's own optimistic UI update; see the
        // protocol doc on `ContactRepository.observeTracked()`).
        let first = try #require(await iterator.next())
        #expect(Set(first.map(\.id)).contains(observed.id))
    }

    @Test(
        "observeTracked never emits an untracked or archived contact",
        arguments: RepositoryContractBackend.allCases
    )
    func observeTrackedExcludesUntrackedAndArchived(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let stream = await repositories.contacts.observeTracked()
        var iterator = stream.makeAsyncIterator()

        let untracked = contractContact(id: try contractUUID(132), suffix: "observed-untracked", tracked: false)
        try await repositories.contacts.upsert(untracked)

        let afterUntracked = try #require(await iterator.next())
        #expect(!afterUntracked.map(\.id).contains(untracked.id))

        let archived = contractContact(
            id: try contractUUID(133),
            suffix: "observed-archived",
            tracked: true,
            archivedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try await repositories.contacts.upsert(archived)

        let afterArchived = try #require(await iterator.next())
        #expect(!afterArchived.map(\.id).contains(archived.id))
    }

    /// A group delete clears `contactGroupId` on every member — a real write
    /// to the Contact table — even though the *filtered* tracked set it
    /// leaves behind is unchanged. GRDB's region-based observation fires on
    /// that write regardless; the mock previously didn't, a silent drift
    /// this pins against regressing.
    @Test(
        "observeTracked emits after a group delete clears a member's contactGroupId",
        arguments: RepositoryContractBackend.allCases
    )
    func observeTrackedEmitsOnGroupDelete(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let primaryID = try contractUUID(134)
        let group = ContactGroup(
            id: try contractUUID(135),
            displayName: "Contract group",
            primaryContactId: primaryID
        )
        try await repositories.contacts.upsert(
            contractContact(id: primaryID, suffix: "group-delete-primary", tracked: true)
        )
        try await repositories.groups.upsert(group)
        try await repositories.contacts.upsert(
            contractContact(id: primaryID, suffix: "group-delete-primary", tracked: true, groupID: group.id)
        )

        let stream = await repositories.contacts.observeTracked()
        var iterator = stream.makeAsyncIterator()

        try await repositories.groups.delete(id: group.id)

        // The emission itself is what's under test, not its content: both
        // backends must broadcast after a group delete, even though
        // clearing `contactGroupId` alone doesn't change who's tracked.
        let afterDelete = try #require(await iterator.next())
        #expect(Set(afterDelete.map(\.id)).contains(primaryID))
    }
}
