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

    /// Round 9: a `fetchAllContacts()` that comes back wholesale empty while
    /// the store previously held active contacts is indistinguishable, on a
    /// single pass, from "the user is mid-restore from an iCloud/device
    /// backup and Contacts hasn't repopulated yet" — treating it as
    /// evidence every contact was deleted would archive the whole address
    /// book on a false read. The two-pass rule below defers on the first
    /// miss and only archives once the *same* refs are still missing on the
    /// very next `.authorized` pass (see `partialReadDefersArchiveUntilSecondConsecutiveMiss`
    /// for the non-degenerate, partially-visible shape of this same rule).
    @Test("A wholesale-empty fetch under .authorized defers archiving to a second consecutive miss")
    func wholesaleEmptyFetchDefersArchiveUntilSecondConsecutiveMiss() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let contactA = Contact(systemContactRef: "still-stored-a", displayName: "A", tracked: true, cadenceDays: 7)
        let contactB = Contact(systemContactRef: "still-stored-b", displayName: "B", tracked: true, cadenceDays: 30)
        try await repo.upsert(contactA)
        try await repo.upsert(contactB)
        let source = MutableContactsSource(status: .authorized, contacts: [])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let firstPass = try await reconciler.reconcile()
        #expect(firstPass.archived == 0)
        let reloadedAAfterFirstPass = try #require(try await repo.fetch(id: contactA.id))
        let reloadedBAfterFirstPass = try #require(try await repo.fetch(id: contactB.id))
        #expect(reloadedAAfterFirstPass.archivedAt == nil)
        #expect(reloadedBAfterFirstPass.archivedAt == nil)

        // Still wholesale-empty on the very next pass — a genuine
        // mass-deletion (or the user revoking and the store staying
        // legitimately empty) rather than a resync that would have
        // repopulated by now.
        let secondPass = try await reconciler.reconcile(previouslyMissingRefs: firstPass.missingRefs)
        #expect(secondPass.archived == 2)
        let reloadedAAfterSecondPass = try #require(try await repo.fetch(id: contactA.id))
        let reloadedBAfterSecondPass = try #require(try await repo.fetch(id: contactB.id))
        #expect(reloadedAAfterSecondPass.archivedAt == Self.now)
        #expect(reloadedBAfterSecondPass.archivedAt == Self.now)
    }

    /// Round 9: the wholesale-empty case above is the degenerate 0-of-N
    /// shape of a more general ambiguity — a *partial* read (some refs
    /// visible, most not) is exactly as ambiguous on a single pass, since
    /// nothing distinguishes "these refs were deleted" from "the resync
    /// hasn't gotten to them yet". 2-of-50 visible pins the non-degenerate
    /// case explicitly.
    @Test("A partial read (2-of-50 visible) defers archiving until a second consecutive miss confirms it")
    func partialReadDefersArchiveUntilSecondConsecutiveMiss() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        var stored: [Contact] = []
        for index in 0..<50 {
            let contact = Contact(systemContactRef: "bulk-\(index)", displayName: "Bulk \(index)", tracked: true)
            try await repo.upsert(contact)
            stored.append(contact)
        }
        let visibleRefs = Set(["bulk-0", "bulk-1"])
        let source = MutableContactsSource(status: .authorized, contacts: visibleRefs.map { ref in
            SystemContact(identifier: ref, givenName: ref, familyName: "", phoneNumbers: [], emailAddresses: [])
        })
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let firstPass = try await reconciler.reconcile()
        #expect(firstPass.archived == 0, "a single ambiguous partial read must not archive anything")
        for contact in stored where !visibleRefs.contains(contact.systemContactRef) {
            let reloaded = try #require(try await repo.fetch(id: contact.id))
            #expect(reloaded.archivedAt == nil)
        }

        // Genuine-deletion control: the same 48 refs are still missing on
        // the very next `.authorized` pass — this is what actually
        // distinguishes a real deletion from a resync that would have
        // repopulated some of them by now.
        let secondPass = try await reconciler.reconcile(previouslyMissingRefs: firstPass.missingRefs)
        #expect(secondPass.archived == 48)
        for contact in stored where !visibleRefs.contains(contact.systemContactRef) {
            let reloaded = try #require(try await repo.fetch(id: contact.id))
            #expect(reloaded.archivedAt == Self.now)
        }
        for ref in visibleRefs {
            let stillVisible = try #require(stored.first { $0.systemContactRef == ref })
            let reloaded = try #require(try await repo.fetch(id: stillVisible.id))
            #expect(reloaded.archivedAt == nil)
        }
    }

    @Test("A genuine deletion under .authorized still archives, proving the .limited guard is scoped correctly")
    func authorizedStillArchivesADeletedContact() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let deleted = Contact(systemContactRef: "truly-deleted", displayName: "Gone", tracked: true)
        try await repo.upsert(deleted)
        let stillVisible = Contact(systemContactRef: "still-visible", displayName: "Still Visible")
        try await repo.upsert(stillVisible)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "still-visible", givenName: "Still", familyName: "Visible",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let firstPass = try await reconciler.reconcile()
        #expect(firstPass.archived == 0)

        let secondPass = try await reconciler.reconcile(previouslyMissingRefs: firstPass.missingRefs)

        #expect(secondPass.archived == 1)
        let reloaded = try #require(try await repo.fetch(id: deleted.id))
        #expect(reloaded.archivedAt == Self.now)
    }
}
