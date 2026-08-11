import Foundation
import Testing
@testable import Regards

/// Tests for `ContactsReconciler` (PR21 / ARCHITECTURE.md §7 "Re-import &
/// reconciliation"). Avoids `CNContactStore` entirely by injecting a
/// `MutableContactsSource`; the only thing CI runs against is the
/// in-memory GRDB DB plus the fake.
struct ContactsReconcilerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A new system contact is imported untracked")
    func reconcileImportsNewContact() async throws {
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "new-1", givenName: "New", familyName: "Person",
                          phoneNumbers: ["+15555550900"], emailAddresses: []),
        ])
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(imported: 1))
        let stored = try await repo.fetchAll()
        #expect(stored.map(\.systemContactRef) == ["new-1"])
        #expect(stored.first?.tracked == false)
    }

    @Test("A system contact the store no longer exposes archives on the second consecutive miss, never deleted")
    func reconcileArchivesDeletedSystemContact() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let existing = Contact(
            systemContactRef: "gone-1",
            displayName: "Gone Contact",
            tracked: true, cadenceDays: 14,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+15555550901"
        )
        try await repo.upsert(existing)
        let stillPresent = Contact(
            systemContactRef: "present-1",
            displayName: "Present Contact",
            preferredChannel: .phoneCall
        )
        try await repo.upsert(stillPresent)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "present-1", givenName: "Present", familyName: "Contact",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let clock = MutableClock(Self.now)
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: clock.now)

        // Round 9: a ref only archives once it's missing on two consecutive
        // `.authorized` passes (see `ContactsReconcilerAuthorizationTests`
        // for the dedicated ambiguous-partial-read regression) — the first
        // pass here just records "gone-1" as newly missing, not archived.
        // Round 10: those two passes also need to be genuinely time-apart
        // (`ContactsReconciler.archiveDebounceFloor`) — see
        // `ContactsReconcilerAuthorizationTests` for the dedicated
        // rapid-vs-floored regression pinning that specifically.
        let firstPass = try await reconciler.reconcile()
        #expect(firstPass.archived == 0)
        let stillActiveAfterFirstPass = try await repo.fetch(id: existing.id)
        #expect(stillActiveAfterFirstPass?.archivedAt == nil)

        clock.advance(by: ContactsReconciler.archiveDebounceFloor)
        let secondPass = try await reconciler.reconcile(previouslyMissingRefs: firstPass.missingRefs)

        #expect(secondPass.archived == 1)
        let reloaded = try await repo.fetch(id: existing.id)
        #expect(reloaded?.archivedAt == clock.now())
        // History-bearing fields survive archival untouched.
        #expect(reloaded?.tracked == true)
        #expect(reloaded?.cadenceDays == 14)
    }

    @Test("A re-selected limited-access contact is un-archived, not re-imported as a new row")
    func reconcileUnarchivesReappearingContact() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let archived = Contact(
            systemContactRef: "limited-1",
            displayName: "Old Name",
            tracked: true,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+15555550902",
            archivedAt: Self.now.addingTimeInterval(-86_400)
        )
        try await repo.upsert(archived)
        let source = MutableContactsSource(status: .limited, contacts: [
            SystemContact(identifier: "limited-1", givenName: "New", familyName: "Name",
                          phoneNumbers: ["+15555550902"], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(unarchived: 1))
        let stored = try await repo.fetchAll()
        #expect(stored.count == 1)
        let reloaded = try #require(stored.first)
        #expect(reloaded.id == archived.id)
        #expect(reloaded.archivedAt == nil)
        #expect(reloaded.displayName == "New Name")
        // User-owned fields are untouched by reconciliation.
        #expect(reloaded.tracked == true)
    }

    @Test("Changed name/phones/emails refresh the existing row without touching user-owned fields")
    func reconcileRefreshesChangedFields() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let existing = Contact(
            systemContactRef: "changed-1",
            displayName: "Old Name",
            tracked: true, cadenceDays: 30,
            priorityTier: .close,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+15555550903",
            phoneNumbers: ["+15555550903"],
            emailAddresses: [],
            notes: "User notes stay"
        )
        try await repo.upsert(existing)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "changed-1", givenName: "New", familyName: "Name",
                          phoneNumbers: ["+15555550904"], emailAddresses: ["new@example.com"]),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(refreshed: 1))
        let reloaded = try #require(try await repo.fetch(id: existing.id))
        #expect(reloaded.displayName == "New Name")
        #expect(reloaded.phoneNumbers == ["+15555550904"])
        #expect(reloaded.emailAddresses == ["new@example.com"])
        // User-owned fields untouched.
        #expect(reloaded.tracked == true)
        #expect(reloaded.cadenceDays == 30)
        #expect(reloaded.priorityTier == .close)
        #expect(reloaded.preferredChannel == .phoneCall)
        // Fix 8: `preferredChannelValue` is re-derived, not preserved
        // verbatim — the old number is no longer among this contact's
        // phones, so keeping it would leave a deep link dialing a number
        // this contact doesn't have anymore.
        #expect(reloaded.preferredChannelValue == "+15555550904")
        #expect(reloaded.notes == "User notes stay")
    }

    @Test("A preferred channel this pass doesn't re-derive is left alone even if its backing data changes")
    func reconcileLeavesNonDerivedPreferredChannelValueAlone() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let existing = Contact(
            systemContactRef: "whatsapp-1",
            displayName: "Old Name",
            tracked: true,
            preferredChannel: .whatsapp,
            preferredChannelValue: "+15555550903",
            phoneNumbers: ["+15555550903"],
            emailAddresses: []
        )
        try await repo.upsert(existing)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "whatsapp-1", givenName: "New", familyName: "Name",
                          phoneNumbers: ["+15555550904"], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(refreshed: 1))
        let reloaded = try #require(try await repo.fetch(id: existing.id))
        #expect(reloaded.preferredChannel == .whatsapp)
        // Not because WhatsApp has no phone data to re-derive from — it's
        // phone-sourced exactly like `.phoneCall`
        // (`ChannelCatalog.metadata(for: .whatsapp).valueKind == .phoneE164`).
        // `redeterminedPreferredChannelValue` only re-derives `.phoneCall`/
        // `.email` today; leaving `.whatsapp` (and `sms`/`signal`/`facetime`)
        // stale here is a known scope gap, not evidence the value is
        // unrecoverable — see that function's doc comment.
        #expect(reloaded.preferredChannelValue == "+15555550903")
    }

    @Test("A re-derived preferred phone/email that's still present is left byte-identical")
    func reconcilePreservesPreferredValueStillPresentAfterRefresh() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let existing = Contact(
            systemContactRef: "kept-1",
            displayName: "Old Name",
            tracked: true,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+15555550903",
            phoneNumbers: ["+15555550903"],
            emailAddresses: []
        )
        try await repo.upsert(existing)
        let source = MutableContactsSource(status: .authorized, contacts: [
            // Display name changes; the phone that's already preferred
            // stays in the refreshed array, just joined by a second one.
            SystemContact(identifier: "kept-1", givenName: "New", familyName: "Name",
                          phoneNumbers: ["+15555550903", "+15555550999"], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(refreshed: 1))
        let reloaded = try #require(try await repo.fetch(id: existing.id))
        #expect(reloaded.preferredChannelValue == "+15555550903")
    }

    @Test("An unchanged system contact is neither written nor counted as refreshed")
    func reconcileLeavesUnchangedContactAlone() async throws {
        let repo = RecordingWriteContactRepository()
        let existing = Contact(
            systemContactRef: "same-1",
            displayName: "Same Name",
            tracked: false,
            phoneNumbers: ["+15555550905"],
            emailAddresses: []
        )
        try await repo.upsert(existing)
        await repo.resetWriteCount()
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "same-1", givenName: "Same", familyName: "Name",
                          phoneNumbers: ["+15555550905"], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(unchanged: 1))
        #expect(await repo.writeCount() == 0)
    }

    @Test("A corrupt row is neither reconciled, refreshed, nor archived")
    func reconcileLeavesCorruptRowUntouched() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let environment = ProductionRepositoryFactory.makeEnvironment(database: database)
        let corrupt = Contact(
            systemContactRef: "corrupt-1",
            displayName: "Corrupt",
            tracked: false,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+15555550906"
        )
        try await environment.contacts.upsert(corrupt)
        try await database.write { db in
            try db.execute(
                sql: "UPDATE Contact SET phonesJson = ? WHERE id = ?",
                arguments: ["null", corrupt.id.uuidString]
            )
        }
        // The system still reports the same identifier — a naive
        // reconciler that ignores corruption would try to overwrite it.
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "corrupt-1", givenName: "Corrupt", familyName: "",
                          phoneNumbers: ["+15555550906"], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: environment.contacts, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init())
        let storedRows = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM Contact")
        }
        #expect(storedRows == 1)
        let phonesJson = try await database.read { db in
            try String.fetchOne(db, sql: "SELECT phonesJson FROM Contact WHERE id = ?",
                                 arguments: [corrupt.id.uuidString])
        }
        #expect(phonesJson == "null")
    }

    @Test("Limited authorization reconciles against exactly the visible subset")
    func reconcileAcceptsLimitedAuthorization() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let source = MutableContactsSource(status: .limited, contacts: [
            SystemContact(identifier: "limited-visible", givenName: "Visible", familyName: "",
                          phoneNumbers: ["+15555550907"], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(imported: 1))
    }

    @Test("Reconciling without authorization throws")
    func reconcileThrowsWhenNotAuthorized() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let source = MutableContactsSource(status: .denied, contacts: [])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        do {
            _ = try await reconciler.reconcile()
            Issue.record("Expected ContactsReconciler.ReconciliationError.notAuthorized")
        } catch let ContactsReconciler.ReconciliationError.notAuthorized(status) {
            #expect(status == .denied)
        }
    }

    @Test("A per-row write failure during reconciliation is counted, not silently dropped")
    func reconcileTolerantOfOneRowFailure() async throws {
        let repo = FailingWriteContactRepository(failingIdentifiers: ["broken-1"])
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "broken-1", givenName: "Broken", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
            SystemContact(identifier: "ok-1", givenName: "OK", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(imported: 1, failed: 1))
    }
}

// MARK: - Fakes
//
// `MutableContactsSource`, `RecordingWriteContactRepository`, and
// `FailingWriteContactRepository` live in RegardsTests/Support — shared
// across the reconciler and launch-coordinator reconciliation suites.
