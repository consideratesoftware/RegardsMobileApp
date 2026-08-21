import Foundation
import GRDB
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

    /// Pins the same R23 parity `observeTrackedEmitsOnGroupDelete` above
    /// pins, for `updateReconciledFields` instead of `deleteGroup`:
    /// `MockStore.updateReconciledFields` didn't call
    /// `broadcastTrackedChange()`, while GRDB's real `UPDATE` fires
    /// `observeTracked()`'s region-based observation on any write to the
    /// Contact table. Flipping `archivedAt` here specifically (not just
    /// `displayName`) is deliberate: an archiving reconciliation write is
    /// the shape whose *filtered* tracked set could plausibly change too, so
    /// it's the case most likely to have been "accidentally correct" if the
    /// broadcast were only reached through some other path — this test
    /// wants the direct call, not a coincidence.
    @Test(
        "observeTracked emits after updateReconciledFields archives a contact",
        arguments: RepositoryContractBackend.allCases
    )
    func observeTrackedEmitsOnReconciledFieldsUpdate(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contactID = try contractUUID(136)
        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "reconciled-update", tracked: true)
        )

        let stream = await repositories.contacts.observeTracked()
        var iterator = stream.makeAsyncIterator()

        try await repositories.contacts.updateReconciledFields(
            id: contactID,
            fields: ReconciledContactFields(
                displayName: "Reconciled Update",
                phoneNumbers: [],
                emailAddresses: [],
                preferredChannelValue: "",
                archivedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )

        // Content, not just emission: this write also removes the contact
        // from the tracked set, so the next emission should no longer
        // contain it.
        let afterUpdate = try #require(await iterator.next())
        #expect(!afterUpdate.map(\.id).contains(contactID))
    }

    /// Blocker (staged review round 6): "Caught up" and "Log other channel…"
    /// went through `InteractionLogging`'s `contacts.upsert` when the
    /// cross-screen live-update tests (`OverdueViewModelActionTests`/
    /// `UpcomingViewModelActionTests`'
    /// `liveUpdateReflectsWriteFromAnotherReference`) were written, so those
    /// tests hand-rolling an `upsert` genuinely exercised the production
    /// write path at the time. `InteractionLogging.record()` now writes
    /// through the field-scoped `updateLastInteractedAt` instead (TF-03/R23
    /// parity fix), and nothing had re-proven `observeTracked()` still fires
    /// on *that* write specifically — same shape as
    /// `observeTrackedEmitsOnReconciledFieldsUpdate` above pins for
    /// `updateReconciledFields`, which is exactly the sibling bug that method
    /// exists to catch: a field-scoped write that forgets to broadcast.
    @Test(
        "observeTracked emits after updateLastInteractedAt moves a contact's last-contacted date",
        arguments: RepositoryContractBackend.allCases
    )
    func observeTrackedEmitsOnUpdateLastInteractedAt(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contactID = try contractUUID(137)
        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "last-interacted-update", tracked: true)
        )

        let stream = await repositories.contacts.observeTracked()
        var iterator = stream.makeAsyncIterator()

        _ = try await repositories.contacts.updateLastInteractedAt(
            id: contactID,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        // The emission itself is what's under test: both backends must
        // broadcast after this write, even though the tracked *set* is
        // unchanged by it (only a field on an already-tracked row moved).
        let afterUpdate = try #require(await iterator.next())
        #expect(Set(afterUpdate.map(\.id)).contains(contactID))
    }
    /// Staged review round 13, coverage gap: `CancellableBoxTests` covers
    /// the cancellation box in isolation, but nothing drove a *real* GRDB
    /// observation failure through `observeTracked()`'s `onError`. This does
    /// — no fake repository, no injected sentinel error. Dropping the table
    /// the observation reads leaves `ContactRecord.fetchAll` with nothing to
    /// fetch, so GRDB itself raises the error and `onError` runs for real.
    ///
    /// What it pins is the contract the ViewModels depend on: the stream
    /// *ends* (`continuation.finish()`) rather than hanging forever or
    /// throwing into the consumer. `OverdueViewModel`/`UpcomingViewModel`'s
    /// `for await` loop falls out on exactly this, which is what lets them
    /// clear the observation token and re-subscribe on the next `load()`.
    /// A stream that hung here instead would strand that token non-nil and
    /// silently kill live updates for the rest of the process.
    /// The fault shape is deliberate, and two more obvious ones do **not**
    /// work — both were tried here and neither reaches `onError`:
    /// `DROP TABLE Contact` stops the observation being notified at all (the
    /// test hangs on `iterator.next()` forever rather than ending), and
    /// corrupting a value (`UPDATE Contact SET lastInteractedAt =
    /// 'not-a-number'`) is absorbed — the fetch still succeeds and the
    /// stream emits normally. Only a *schema* failure that keeps the tracked
    /// region intact makes the fetch itself throw. Worth knowing before
    /// "simplifying" this setup into either of those.
    @Test("A real GRDB observation error ends the stream rather than hanging the consumer")
    func observeTrackedEndsStreamOnRealGRDBError() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabase()
        let repositories = GRDBRepositories(dbQueue: dbQueue)
        let seeded = contractContact(id: try contractUUID(525), suffix: "observe-error", tracked: true)
        try await repositories.contacts.upsert(seeded)
        let stream = await repositories.contacts.observeTracked()
        var iterator = stream.makeAsyncIterator()

        // A real, unrecoverable fetch failure that still leaves the
        // observed region intact, so the observation is notified and its
        // fetch is the thing that fails. `displayName` is `NOT NULL` and
        // carries no index, so SQLite permits dropping it; `ContactRecord`
        // requires it, so `fetchAll` throws while decoding. The `UPDATE` in
        // the same transaction guarantees the commit notification.
        try await dbQueue.write { db in
            try db.execute(sql: "ALTER TABLE Contact DROP COLUMN displayName")
            try db.execute(sql: "UPDATE Contact SET notes = 'observation-error-probe'")
        }

        #expect(await iterator.next() == nil)
    }
}
