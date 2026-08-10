import Foundation
import Testing
@testable import Regards

/// Blocker: under `.limited`, `fetchAllContacts()` only ever returns the
/// picker-selected subset, so a stored contact outside it isn't evidence of
/// deletion. Archiving it anyway would silently hide a still-real contact
/// on every deselection, and on every `.authorized → .limited` downgrade —
/// which ARCHITECTURE.md §21 explicitly calls out as the kind of Contacts
/// permission-model drift most likely to break silently. These regressions
/// pin the ruling: deselection (and a downgrade) must be a no-op for
/// archiving, never an archive.
struct ContactsReconcilerAuthorizationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A stored contact absent from a .limited visible subset is never archived")
    func limitedNeverArchivesAContactOutsideTheVisibleSubset() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let outsideSelection = Contact(
            systemContactRef: "not-selected",
            displayName: "Not In The Picker",
            tracked: true, cadenceDays: 14
        )
        try await repo.upsert(outsideSelection)
        let source = MutableContactsSource(status: .limited, contacts: [
            SystemContact(identifier: "selected-1", givenName: "Selected", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result.archived == 0)
        let reloaded = try #require(try await repo.fetch(id: outsideSelection.id))
        #expect(reloaded.archivedAt == nil)
        #expect(reloaded.tracked == true)
        #expect(reloaded.cadenceDays == 14)
    }

    @Test("An .authorized → .limited downgrade between two passes archives nothing")
    func authorizedToLimitedDowngradeArchivesNothing() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let contactA = Contact(systemContactRef: "contact-a", displayName: "A", tracked: true)
        let contactB = Contact(systemContactRef: "contact-b", displayName: "B", tracked: true)
        try await repo.upsert(contactA)
        try await repo.upsert(contactB)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "contact-a", givenName: "A", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
            SystemContact(identifier: "contact-b", givenName: "B", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let firstPass = try await reconciler.reconcile()
        #expect(firstPass.archived == 0)

        // The user downgrades to limited access and only "contact-a" is in
        // the new picker selection — "contact-b" disappears from what
        // `fetchAllContacts()` reports, but it was never actually deleted.
        source.setStatus(.limited)
        source.setContacts([
            SystemContact(identifier: "contact-a", givenName: "A", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])

        let secondPass = try await reconciler.reconcile()

        #expect(secondPass.archived == 0)
        let reloadedB = try #require(try await repo.fetch(id: contactB.id))
        #expect(reloadedB.archivedAt == nil)
    }

    /// TOCTOU nit: `fetchAllContacts()` can take a while (a full
    /// enumeration, off-pool per R25), and the user can downgrade
    /// permissions mid-pass. The reconciler re-reads status after the fetch
    /// and requires *both* reads say `.authorized` before archiving — this
    /// pins that a downgrade landing exactly inside the fetch call (not just
    /// between two separate passes, which the test above already covers)
    /// still archives nothing.
    @Test("An .authorized → .limited downgrade landing mid-fetchAllContacts archives nothing")
    func downgradeDuringFetchArchivesNothing() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let stillReal = Contact(systemContactRef: "still-real", displayName: "Still Real", tracked: true)
        try await repo.upsert(stillReal)
        // The store reports nothing visible — as if `stillReal` had been
        // deleted — but the hook flips status to `.limited` right as the
        // enumeration finishes, simulating the downgrade landing *during*
        // the call rather than cleanly between two passes.
        let source = MutableContactsSource(status: .authorized, contacts: [])
        source.setFetchAllContactsHook {
            source.setStatus(.limited)
        }
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result.archived == 0)
        let reloaded = try #require(try await repo.fetch(id: stillReal.id))
        #expect(reloaded.archivedAt == nil)
    }

    /// Fix 3: a `fetchAllContacts()` that comes back wholesale empty while
    /// the store previously held active contacts is indistinguishable from
    /// "the user is mid-restore from an iCloud/device backup and Contacts
    /// hasn't repopulated yet" — treating it as evidence every contact was
    /// deleted would archive the whole address book in one pass on a false
    /// read. This shape skips the sweep entirely rather than guess.
    @Test("A wholesale-empty fetch under .authorized skips the archive sweep instead of mass-archiving")
    func wholesaleEmptyFetchArchivesNothing() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let contactA = Contact(systemContactRef: "still-stored-a", displayName: "A", tracked: true, cadenceDays: 7)
        let contactB = Contact(systemContactRef: "still-stored-b", displayName: "B", tracked: true, cadenceDays: 30)
        try await repo.upsert(contactA)
        try await repo.upsert(contactB)
        let source = MutableContactsSource(status: .authorized, contacts: [])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result.archived == 0)
        let reloadedA = try #require(try await repo.fetch(id: contactA.id))
        let reloadedB = try #require(try await repo.fetch(id: contactB.id))
        #expect(reloadedA.archivedAt == nil)
        #expect(reloadedB.archivedAt == nil)
    }

    @Test("A genuine deletion under .authorized still archives, proving the .limited guard is scoped correctly")
    func authorizedStillArchivesADeletedContact() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let deleted = Contact(systemContactRef: "truly-deleted", displayName: "Gone", tracked: true)
        try await repo.upsert(deleted)
        // A second, still-visible contact keeps the fetch from being
        // wholesale-empty — the mass-archive guard (`ContactsReconcilerTests
        // .reconcileWholesaleEmptyFetchArchivesNothing`) specifically skips
        // the sweep when the store held contacts but the fetch reports none
        // at all, so a single-contact deletion needs at least one other
        // contact the store still reports to prove archiving itself (not
        // that guard) is what this test exercises.
        let stillVisible = Contact(systemContactRef: "still-visible", displayName: "Still Visible")
        try await repo.upsert(stillVisible)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "still-visible", givenName: "Still", familyName: "Visible",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result.archived == 1)
        let reloaded = try #require(try await repo.fetch(id: deleted.id))
        #expect(reloaded.archivedAt == Self.now)
    }
}
