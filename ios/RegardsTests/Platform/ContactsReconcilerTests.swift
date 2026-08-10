import Foundation
import Testing
@testable import Regards

/// Tests for `ContactsReconciler` (PR21 / ARCHITECTURE.md §7 "Re-import &
/// reconciliation"). Avoids `CNContactStore` entirely by injecting a
/// `ReconcilerFakeContactsSource`; the only thing CI runs against is the
/// in-memory GRDB DB plus the fake.
struct ContactsReconcilerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A new system contact is imported untracked")
    func reconcileImportsNewContact() async throws {
        let source = ReconcilerFakeContactsSource(status: .authorized, contacts: [
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

    @Test("A system contact the store no longer exposes is archived, never deleted")
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
        let source = ReconcilerFakeContactsSource(status: .authorized, contacts: [])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(archived: 1))
        let reloaded = try await repo.fetch(id: existing.id)
        #expect(reloaded?.archivedAt == Self.now)
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
        let source = ReconcilerFakeContactsSource(status: .limited, contacts: [
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
            preferredChannel: .whatsapp,
            preferredChannelValue: "+15555550903",
            phoneNumbers: ["+15555550903"],
            emailAddresses: [],
            notes: "User notes stay"
        )
        try await repo.upsert(existing)
        let source = ReconcilerFakeContactsSource(status: .authorized, contacts: [
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
        #expect(reloaded.preferredChannel == .whatsapp)
        #expect(reloaded.preferredChannelValue == "+15555550903")
        #expect(reloaded.notes == "User notes stay")
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
        let source = ReconcilerFakeContactsSource(status: .authorized, contacts: [
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
        let source = ReconcilerFakeContactsSource(status: .authorized, contacts: [
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
        let source = ReconcilerFakeContactsSource(status: .limited, contacts: [
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
        let source = ReconcilerFakeContactsSource(status: .denied, contacts: [])
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
        let source = ReconcilerFakeContactsSource(status: .authorized, contacts: [
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

private actor ReconcilerFakeContactsSource: ContactsSource {
    private let status: ContactsAuthorizationStatus
    private let contacts: [SystemContact]

    init(status: ContactsAuthorizationStatus, contacts: [SystemContact]) {
        self.status = status
        self.contacts = contacts
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus { status }
    func requestAccess() async throws -> ContactsAuthorizationStatus { status }
    func fetchAllContacts() async throws -> [SystemContact] { contacts }
}

/// A `ContactRepository` that records writes so a test can prove
/// reconciliation skipped an unchanged contact rather than writing it
/// through unconditionally.
private actor RecordingWriteContactRepository: ContactRepository {
    private var contacts: [UUID: Contact] = [:]
    private var writes = 0

    func fetchAll() async throws -> [Contact] { Array(contacts.values) }
    func fetchTracked() async throws -> [Contact] {
        contacts.values.filter { $0.tracked && $0.isActive }
    }
    func fetch(id: UUID) async throws -> Contact? { contacts[id] }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        contacts.values.filter { $0.contactGroupId == groupId }
    }
    func upsert(_ contact: Contact) async throws {
        writes += 1
        contacts[contact.id] = contact
    }
    func archive(id: UUID, at: Date) async throws {
        writes += 1
        contacts[id]?.archivedAt = at
    }
    func resetWriteCount() { writes = 0 }
    func writeCount() -> Int { writes }
}

private enum ReconcileRowFailure: Error {
    case failed
}

/// Fails every `upsert` whose `systemContactRef` is in `failingIdentifiers`.
private actor FailingWriteContactRepository: ContactRepository {
    private var contacts: [UUID: Contact] = [:]
    private let failingIdentifiers: Set<String>

    init(failingIdentifiers: Set<String>) {
        self.failingIdentifiers = failingIdentifiers
    }

    func fetchAll() async throws -> [Contact] { Array(contacts.values) }
    func fetchTracked() async throws -> [Contact] {
        contacts.values.filter { $0.tracked && $0.isActive }
    }
    func fetch(id: UUID) async throws -> Contact? { contacts[id] }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        contacts.values.filter { $0.contactGroupId == groupId }
    }
    func upsert(_ contact: Contact) async throws {
        guard !failingIdentifiers.contains(contact.systemContactRef) else {
            throw ReconcileRowFailure.failed
        }
        contacts[contact.id] = contact
    }
    func archive(id: UUID, at: Date) async throws {
        contacts[id]?.archivedAt = at
    }
}
