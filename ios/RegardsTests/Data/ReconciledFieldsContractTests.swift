import Foundation
import Testing
@testable import Regards

/// Should-fix (TF-03 hosted review, round 7/8): `ContactRepository
/// .updateReconciledFields` must behave identically on both backends —
/// `GRDBContactRepository`'s real column-scoped `UPDATE` and
/// `MockContactRepository`'s dictionary-mutation equivalent — since
/// `ContactsReconciler` runs against whichever one the app is wired to
/// (production vs. previews/UI tests). Same parametric-over-`RepositoryContractBackend`
/// pattern as `ContactFetchDiagnosticsContractTests`.
struct ReconciledFieldsContractTests {
    @Test(
        "updateReconciledFields writes exactly the five reconciled columns",
        arguments: RepositoryContractBackend.allCases
    )
    func writesOnlyReconciledFields(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        // `contractContact` seeds every field `updateReconciledFields` must
        // *not* touch: `tracked`/`cadenceDays`/`priorityTier` (user-owned
        // scheduling), `reminderWindowOverride`, `lastInteractedAt`, `notes`,
        // `photoRef`, `preferredChannel` (the enum, as opposed to
        // `preferredChannelValue`), `createdAt`, and `systemContactRef`.
        let original = contractContact(
            id: try contractUUID(151),
            suffix: "reconciled-fields",
            tracked: true
        )
        try await repositories.contacts.upsert(original)
        let storedOriginal = try #require(try await repositories.contacts.fetch(id: original.id))

        try await repositories.contacts.updateReconciledFields(
            id: original.id,
            fields: ReconciledContactFields(
                displayName: "Reconciled Name",
                phoneNumbers: ["+1 415 555 0199"],
                emailAddresses: ["reconciled@example.com"],
                preferredChannelValue: "reconciled@example.com",
                archivedAt: nil
            )
        )

        let reloaded = try #require(try await repositories.contacts.fetch(id: original.id))

        // The five fields `updateReconciledFields` owns.
        #expect(reloaded.displayName == "Reconciled Name")
        #expect(reloaded.phoneNumbers == ["+1 415 555 0199"])
        #expect(reloaded.emailAddresses == ["reconciled@example.com"])
        #expect(reloaded.preferredChannelValue == "reconciled@example.com")
        #expect(reloaded.archivedAt == nil)

        // Everything else must be byte-identical to what was stored before
        // the call — not just "unchanged in spirit", but exactly the
        // originally-stored value, including whatever normalization the
        // initial `upsert` already applied (e.g. sub-second timestamp
        // truncation), so this really proves nothing beyond the five
        // fields was re-derived or re-written.
        #expect(reloaded.id == storedOriginal.id)
        #expect(reloaded.systemContactRef == storedOriginal.systemContactRef)
        #expect(reloaded.photoRef == storedOriginal.photoRef)
        #expect(reloaded.tracked == storedOriginal.tracked)
        #expect(reloaded.cadenceDays == storedOriginal.cadenceDays)
        #expect(reloaded.priorityTier == storedOriginal.priorityTier)
        #expect(reloaded.preferredChannel == storedOriginal.preferredChannel)
        #expect(reloaded.reminderWindowOverride == storedOriginal.reminderWindowOverride)
        #expect(reloaded.lastInteractedAt == storedOriginal.lastInteractedAt)
        #expect(reloaded.notes == storedOriginal.notes)
        #expect(reloaded.contactGroupId == storedOriginal.contactGroupId)
        #expect(reloaded.createdAt == storedOriginal.createdAt)
    }

    /// The archive-sweep and un-archive paths both route through this same
    /// method (`archivedAt` is one of the five fields) — pin both
    /// transitions, not just "can write a value".
    @Test(
        "updateReconciledFields can both archive and un-archive via the same archivedAt field",
        arguments: RepositoryContractBackend.allCases
    )
    func archivesAndUnarchivesViaSameField(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(id: try contractUUID(152), suffix: "reconciled-archive")
        try await repositories.contacts.upsert(original)
        let archivedAt = Date(timeIntervalSince1970: 1_800_000_500)

        try await repositories.contacts.updateReconciledFields(
            id: original.id,
            fields: ReconciledContactFields(
                displayName: original.displayName,
                phoneNumbers: original.phoneNumbers,
                emailAddresses: original.emailAddresses,
                preferredChannelValue: original.preferredChannelValue,
                archivedAt: archivedAt
            )
        )
        let archived = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(archived.archivedAt == archivedAt)

        try await repositories.contacts.updateReconciledFields(
            id: original.id,
            fields: ReconciledContactFields(
                displayName: original.displayName,
                phoneNumbers: original.phoneNumbers,
                emailAddresses: original.emailAddresses,
                preferredChannelValue: original.preferredChannelValue,
                archivedAt: nil
            )
        )
        let unarchived = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(unarchived.archivedAt == nil)
    }

    /// A no-op on a nonexistent id, same as `archive(id:at:)` — proves both
    /// backends agree on that edge case too, not just the happy path.
    @Test(
        "updateReconciledFields is a no-op when id doesn't match a stored row",
        arguments: RepositoryContractBackend.allCases
    )
    func noOpForMissingId(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let missingId = try contractUUID(153)

        try await repositories.contacts.updateReconciledFields(
            id: missingId,
            fields: ReconciledContactFields(
                displayName: "Nobody",
                phoneNumbers: [],
                emailAddresses: [],
                preferredChannelValue: "",
                archivedAt: nil
            )
        )

        let fetched = try await repositories.contacts.fetch(id: missingId)
        #expect(fetched == nil)
    }
}
