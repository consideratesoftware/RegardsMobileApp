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
}
