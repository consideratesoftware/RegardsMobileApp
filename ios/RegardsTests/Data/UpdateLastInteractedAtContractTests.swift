import Foundation
import Testing
@testable import Regards

/// Blocker (staged review): `ContactRepository.updateLastInteractedAt` —
/// added the round every "Caught up" and "Log other" action started
/// depending on it — had no contract test on either backend, and
/// `StubContactRepository` had no override, so every view-model action test
/// in this PR was exercising the protocol's generic fetch-then-upsert
/// fallback rather than the field-scoped write GRDB (and now the stub)
/// actually ship. The clobbering-race fix `InteractionLogging.record`
/// depends on was unproven. Same parametric-over-`RepositoryContractBackend`
/// pattern as `ReconciledFieldsContractTests`.
struct UpdateLastInteractedAtContractTests {
    @Test(
        "updateLastInteractedAt writes exactly lastInteractedAt and reports a match",
        arguments: RepositoryContractBackend.allCases
    )
    func writesOnlyLastInteractedAt(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        // `contractContact` seeds every field this write must *not* touch:
        // `displayName`, phone/email arrays, `preferredChannelValue`,
        // `archivedAt`, `tracked`/`cadenceDays`/`priorityTier`,
        // `reminderWindowOverride`, `notes`, `photoRef`, `preferredChannel`,
        // `createdAt`, `systemContactRef`.
        let original = contractContact(
            id: try contractUUID(161),
            suffix: "last-interacted",
            tracked: true
        )
        try await repositories.contacts.upsert(original)
        let storedOriginal = try #require(try await repositories.contacts.fetch(id: original.id))
        let newDate = Date(timeIntervalSince1970: 1_800_000_500)

        let matched = try await repositories.contacts.updateLastInteractedAt(id: original.id, at: newDate)
        #expect(matched)

        let reloaded = try #require(try await repositories.contacts.fetch(id: original.id))

        // The one field this method owns.
        #expect(reloaded.lastInteractedAt == newDate)

        // Everything else must be byte-identical to what was stored before
        // the call — proves this write is genuinely field-scoped, not a
        // whole-row upsert from some other snapshot.
        #expect(reloaded.id == storedOriginal.id)
        #expect(reloaded.systemContactRef == storedOriginal.systemContactRef)
        #expect(reloaded.displayName == storedOriginal.displayName)
        #expect(reloaded.photoRef == storedOriginal.photoRef)
        #expect(reloaded.tracked == storedOriginal.tracked)
        #expect(reloaded.cadenceDays == storedOriginal.cadenceDays)
        #expect(reloaded.priorityTier == storedOriginal.priorityTier)
        #expect(reloaded.preferredChannel == storedOriginal.preferredChannel)
        #expect(reloaded.preferredChannelValue == storedOriginal.preferredChannelValue)
        #expect(reloaded.phoneNumbers == storedOriginal.phoneNumbers)
        #expect(reloaded.emailAddresses == storedOriginal.emailAddresses)
        #expect(reloaded.reminderWindowOverride == storedOriginal.reminderWindowOverride)
        #expect(reloaded.notes == storedOriginal.notes)
        #expect(reloaded.contactGroupId == storedOriginal.contactGroupId)
        #expect(reloaded.archivedAt == storedOriginal.archivedAt)
        #expect(reloaded.createdAt == storedOriginal.createdAt)
    }

    /// The exact case blocker 3/item 9 exists for: a contact archived (or
    /// deleted) between an earlier `fetch` and this write must report `false`,
    /// not silently succeed — `InteractionLogging.record` throws on this so
    /// a caller never announces "Marked X caught up" for a write that
    /// changed nothing.
    @Test(
        "updateLastInteractedAt reports false and writes nothing when id doesn't match a stored row",
        arguments: RepositoryContractBackend.allCases
    )
    func reportsFalseForMissingId(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let missingId = try contractUUID(162)

        let matched = try await repositories.contacts.updateLastInteractedAt(
            id: missingId,
            at: Date(timeIntervalSince1970: 1_800_000_500)
        )

        #expect(!matched)
        let fetched = try await repositories.contacts.fetch(id: missingId)
        #expect(fetched == nil)
    }

    /// Two writes in a row both land, each reporting a match — proves this
    /// isn't a one-shot or idempotent-only write.
    @Test(
        "updateLastInteractedAt applies a second write over the first",
        arguments: RepositoryContractBackend.allCases
    )
    func secondWriteOverwritesFirst(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(id: try contractUUID(163), suffix: "last-interacted-twice", tracked: true)
        try await repositories.contacts.upsert(original)
        let first = Date(timeIntervalSince1970: 1_800_000_100)
        let second = Date(timeIntervalSince1970: 1_800_000_900)

        #expect(try await repositories.contacts.updateLastInteractedAt(id: original.id, at: first))
        #expect(try await repositories.contacts.updateLastInteractedAt(id: original.id, at: second))

        let reloaded = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(reloaded.lastInteractedAt == second)
    }
}
