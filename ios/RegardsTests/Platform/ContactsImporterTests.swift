import Foundation
import Testing
@testable import Regards

/// Tests for the platform-layer Contacts importer. Avoids `CNContactStore`
/// entirely by injecting a `FakeContactsSource`; the only thing CI runs
/// against is the in-memory GRDB DB plus the fake.
struct ContactsImporterTests {

    // MARK: - map(systemContact:now:) — pure rules

    @Test("Display name uses 'Given Family' when both are present")
    func mapDisplayNameFullName() {
        let sc = SystemContact(
            identifier: "id-1",
            givenName: "Priya",
            familyName: "Raghavan",
            phoneNumbers: ["+15555550100"],
            emailAddresses: [])
        let c = ContactsImporter.map(systemContact: sc, now: Self.now)
        #expect(c.displayName == "Priya Raghavan")
    }

    @Test("Display name falls back to the first phone number when name is empty")
    func mapDisplayNameFallsBackToPhone() {
        let sc = SystemContact(
            identifier: "id-2",
            givenName: "",
            familyName: "",
            phoneNumbers: ["+15555550101", "+15555550199"],
            emailAddresses: ["alex@example.com"])
        let c = ContactsImporter.map(systemContact: sc, now: Self.now)
        #expect(c.displayName == "+15555550101")
    }

    @Test("Display name falls back to the first email when name and phones are empty")
    func mapDisplayNameFallsBackToEmail() {
        let sc = SystemContact(
            identifier: "id-3",
            givenName: "",
            familyName: "",
            phoneNumbers: [],
            emailAddresses: ["alex@example.com"])
        let c = ContactsImporter.map(systemContact: sc, now: Self.now)
        #expect(c.displayName == "alex@example.com")
    }

    @Test("Display name falls back to 'Unknown' when nothing else is available")
    func mapDisplayNameFallsBackToUnknown() {
        let sc = SystemContact(
            identifier: "id-4",
            givenName: "",
            familyName: "",
            phoneNumbers: [],
            emailAddresses: [])
        let c = ContactsImporter.map(systemContact: sc, now: Self.now)
        #expect(c.displayName == "Unknown")
    }

    @Test("Preferred channel selects the first valid phone before email")
    func mapPreferredChannelPrefersPhone() {
        let sc = SystemContact(
            identifier: "id-5",
            givenName: "Mom",
            familyName: "",
            phoneNumbers: ["(415) 555-0100", "+15555550200"],
            emailAddresses: ["mom@example.com"])
        let c = ContactsImporter.map(systemContact: sc, now: Self.now)
        #expect(c.preferredChannel == .phoneCall)
        #expect(c.preferredChannelValue == "+15555550200")
        #expect(ChannelCatalog.validate(value: c.preferredChannelValue, for: c.preferredChannel))
    }

    @Test("Preferred channel falls back to email when no valid phone is present")
    func mapPreferredChannelFallsBackToEmail() {
        let sc = SystemContact(
            identifier: "id-6",
            givenName: "Alex",
            familyName: "",
            phoneNumbers: ["(415) 555-0100"],
            emailAddresses: ["Alex@Example.COM"])
        let c = ContactsImporter.map(systemContact: sc, now: Self.now)
        #expect(c.preferredChannel == .email)
        #expect(c.preferredChannelValue == "alex@example.com")
        #expect(ChannelCatalog.validate(value: c.preferredChannelValue, for: c.preferredChannel))
    }

    @Test("Imported contacts always start with tracked == false")
    func mapImportsAreUntracked() {
        let sc = SystemContact(
            identifier: "id-7",
            givenName: "Sam", familyName: "",
            phoneNumbers: ["+15555550300"], emailAddresses: [])
        let c = ContactsImporter.map(systemContact: sc, now: Self.now)
        #expect(c.tracked == false)
        #expect(c.cadenceDays == nil)
    }

    @Test("systemContactRef carries the platform identifier through unchanged")
    func mapPreservesIdentifier() {
        let sc = SystemContact(
            identifier: "ABCDEFGH-1234-5678-9012-ABCDEFGHIJKL",
            givenName: "Ref", familyName: "Test",
            phoneNumbers: ["+15555550400"], emailAddresses: [])
        let c = ContactsImporter.map(systemContact: sc, now: Self.now)
        #expect(c.systemContactRef == "ABCDEFGH-1234-5678-9012-ABCDEFGHIJKL")
    }

    @Test("Mapping normalizes parseable phones and lowercases every email")
    func mapPersistsAllContactValues() {
        let sc = SystemContact(
            identifier: "id-all-values",
            givenName: "Alex",
            familyName: "Chen",
            phoneNumbers: ["+1 555 010 0100", "+44 20 7946 0958"],
            emailAddresses: ["Alex@Example.COM", "WORK@EXAMPLE.COM"]
        )

        let contact = ContactsImporter.map(systemContact: sc, now: Self.now)

        #expect(contact.phoneNumbers == ["+15550100100", "+442079460958"])
        #expect(contact.emailAddresses == ["alex@example.com", "work@example.com"])
        #expect(contact.preferredChannelValue == "+15550100100")
    }

    @Test("Mapping preserves raw phones when an E.164 country code is unavailable")
    func mapPreservesUnparseablePhoneValues() {
        let rawPhones = [
            "(415) 555-0100",
            "extension 123",
            "+1 415 555 0100 x123",
            "+1 415 CALL-NOW",
            "+١ ٤١٥ ٥٥٥ ٠١٠٠",
            "+１ ４１５ ５５５ ０１００",
            "+12",
            "+1234567890123456",
        ]
        let systemContact = SystemContact(
            identifier: "id-local-values",
            givenName: "Alex",
            familyName: "Chen",
            phoneNumbers: rawPhones,
            emailAddresses: []
        )

        let contact = ContactsImporter.map(systemContact: systemContact, now: Self.now)

        #expect(contact.phoneNumbers == rawPhones)
        #expect(contact.preferredChannelValue.isEmpty)
    }

    @Test("Mapping retains an invalid email without selecting it for deep links")
    func mapPreservesInvalidEmailWithoutPreferredValue() {
        let systemContact = SystemContact(
            identifier: "id-invalid-email",
            givenName: "Alex", familyName: "Chen", phoneNumbers: [],
            emailAddresses: ["not-an-email"]
        )

        let contact = ContactsImporter.map(systemContact: systemContact, now: Self.now)

        #expect(contact.preferredChannel == .email)
        #expect(contact.preferredChannelValue.isEmpty)
    }

    // MARK: - runFirstLaunchImport — orchestration

    @Test("Empty source returns 0 imported, 0 skipped")
    func runImportEmptySource() async throws {
        let source = FakeContactsSource(status: .authorized, contacts: [])
        let repo = GRDBRepositories(
            dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let importer = ContactsImporter(source: source, repo: repo,
                                        clock: { Self.now })

        let result = try await importer.runFirstLaunchImport()
        #expect(result == .init(imported: 0, skipped: 0))
        #expect(try await repo.fetchAll().isEmpty)
    }

    @Test("All-new contacts are inserted with imported counter equal to source count")
    func runImportAllNew() async throws {
        let sources = [
            SystemContact(identifier: "id-A", givenName: "Priya", familyName: "R",
                          phoneNumbers: ["+15555550501"], emailAddresses: []),
            SystemContact(identifier: "id-B", givenName: "Mom", familyName: "",
                          phoneNumbers: ["+15555550502"], emailAddresses: []),
            SystemContact(identifier: "id-C", givenName: "Alex", familyName: "Chen",
                          phoneNumbers: [], emailAddresses: ["alex@example.com"]),
        ]
        let source = FakeContactsSource(status: .authorized, contacts: sources)
        let repo = GRDBRepositories(
            dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let importer = ContactsImporter(source: source, repo: repo,
                                        clock: { Self.now })

        let result = try await importer.runFirstLaunchImport()
        #expect(result == .init(imported: 3, skipped: 0))
        #expect(try await repo.fetchAll().count == 3)
    }

    @Test("Import persists all contact values through the repository")
    func runImportPersistsAllContactValues() async throws {
        let systemContact = SystemContact(
            identifier: "id-persist-values",
            givenName: "Alex",
            familyName: "Chen",
            phoneNumbers: ["+1 555 010 0100", "+44 20 7946 0958"],
            emailAddresses: ["Alex@Example.COM", "WORK@EXAMPLE.COM"]
        )
        let source = FakeContactsSource(status: .authorized, contacts: [systemContact])
        let repo = GRDBRepositories(
            dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let importer = ContactsImporter(source: source, repo: repo,
                                        clock: { Self.now })

        _ = try await importer.runFirstLaunchImport()
        let imported = try #require(try await repo.fetchAll().first)

        #expect(imported.phoneNumbers == ["+15550100100", "+442079460958"])
        #expect(imported.emailAddresses == ["alex@example.com", "work@example.com"])
    }

    @Test("Contacts already in the DB are skipped, not duplicated or modified")
    func runImportSkipsExisting() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabase()
        let repo = GRDBRepositories(dbQueue: queue).contacts

        // Pre-seed an existing contact whose systemContactRef matches one
        // the source will return. The importer should leave it alone, not
        // overwrite with the system version.
        let preExisting = Contact(
            systemContactRef: "id-already-here",
            displayName: "Custom Name (user-edited)",
            tracked: true, cadenceDays: 14,
            preferredChannel: .whatsapp,
            preferredChannelValue: "+15555550600")
        try await repo.upsert(preExisting)

        let sources = [
            SystemContact(identifier: "id-already-here",
                          givenName: "System", familyName: "Name",
                          phoneNumbers: ["+15555550600"], emailAddresses: []),
            SystemContact(identifier: "id-new",
                          givenName: "New", familyName: "Person",
                          phoneNumbers: ["+15555550601"], emailAddresses: []),
        ]
        let source = FakeContactsSource(status: .authorized, contacts: sources)
        let importer = ContactsImporter(source: source, repo: repo,
                                        clock: { Self.now })

        let result = try await importer.runFirstLaunchImport()
        #expect(result == .init(imported: 1, skipped: 1))

        // The pre-existing row must still have its user-edited fields.
        let reloaded = try await repo.fetch(id: preExisting.id)
        #expect(reloaded?.displayName == "Custom Name (user-edited)")
        #expect(reloaded?.tracked == true)
        #expect(reloaded?.cadenceDays == 14)
    }

    @Test("Duplicate system identifiers in one fetch are imported once")
    func runImportSkipsDuplicateSystemIdentifierInOnePass() async throws {
        let duplicateIdentifier = "same-pass-duplicate"
        let sources = [
            SystemContact(
                identifier: duplicateIdentifier,
                givenName: "Leia",
                familyName: "Organa",
                phoneNumbers: ["+15555550602"],
                emailAddresses: []
            ),
            SystemContact(
                identifier: duplicateIdentifier,
                givenName: "General",
                familyName: "Organa",
                phoneNumbers: ["+15555550603"],
                emailAddresses: []
            ),
        ]
        let source = FakeContactsSource(status: .authorized, contacts: sources)
        let repo = GRDBRepositories(
            dbQueue: try DatabaseFactory.makeInMemoryDatabase()
        ).contacts
        let importer = ContactsImporter(source: source, repo: repo, clock: { Self.now })

        let result = try await importer.runFirstLaunchImport()

        #expect(result == .init(imported: 1, skipped: 1))
        let imported = try await repo.fetchAll()
        #expect(imported.count == 1)
        #expect(imported.first?.systemContactRef == duplicateIdentifier)
    }

    @Test("Importer throws notAuthorized when current status isn't authorized or limited")
    func runImportThrowsWhenNotAuthorized() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabase()
        let repo = GRDBRepositories(dbQueue: queue).contacts
        let source = FakeContactsSource(status: .denied, contacts: [])
        let importer = ContactsImporter(source: source, repo: repo,
                                        clock: { Self.now })

        // do-catch is intentional over `#expect(throws:)` so the matched
        // status value can be asserted directly.
        do {
            _ = try await importer.runFirstLaunchImport()
            Issue.record("Expected ContactsImporter.ImportError.notAuthorized")
        } catch let ContactsImporter.ImportError.notAuthorized(status) {
            #expect(status == .denied)
        }
    }

    @Test("Limited authorization is treated as authorized for import purposes")
    func runImportAcceptsLimitedAuthorization() async throws {
        let source = FakeContactsSource(
            status: .limited,
            contacts: [SystemContact(identifier: "id-lim",
                                     givenName: "Visible", familyName: "Subset",
                                     phoneNumbers: ["+15555550700"],
                                     emailAddresses: [])])
        let repo = GRDBRepositories(
            dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let importer = ContactsImporter(source: source, repo: repo,
                                        clock: { Self.now })

        let result = try await importer.runFirstLaunchImport()
        #expect(result == .init(imported: 1, skipped: 0))
    }

    @Test("A retry resumes after the last contact written before interruption")
    func runImportResumesAfterInterruption() async throws {
        let sources = [
            SystemContact(identifier: "resume-A", givenName: "A", familyName: "",
                          phoneNumbers: ["+15555550801"], emailAddresses: []),
            SystemContact(identifier: "resume-B", givenName: "B", familyName: "",
                          phoneNumbers: ["+15555550802"], emailAddresses: []),
            SystemContact(identifier: "resume-C", givenName: "C", familyName: "",
                          phoneNumbers: ["+15555550803"], emailAddresses: []),
        ]
        let source = FakeContactsSource(status: .authorized, contacts: sources)
        let repo = InterruptingContactRepository(interruptBeforeWrite: 2)
        let importer = ContactsImporter(source: source, repo: repo,
                                        clock: { Self.now })

        do {
            _ = try await importer.runFirstLaunchImport()
            Issue.record("Expected the first import attempt to be interrupted")
        } catch ImportInterruption.interrupted {
            #expect(try await repo.fetchAll().map(\.systemContactRef) == ["resume-A"])
        }

        let resumed = try await importer.runFirstLaunchImport()
        #expect(resumed == .init(imported: 2, skipped: 1))
        #expect(Set(try await repo.fetchAll().map(\.systemContactRef))
                == Set(sources.map(\.identifier)))
    }

    // MARK: - Helpers

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
}

// MARK: - FakeContactsSource

/// In-memory `ContactsSource` for tests. Status is fixed at construction, and
/// `requestAccess` reports it without touching the system.
private final class FakeContactsSource: ContactsSource, @unchecked Sendable {
    private let lock = NSLock()
    private var status: ContactsAuthorizationStatus
    private var contacts: [SystemContact]

    init(status: ContactsAuthorizationStatus, contacts: [SystemContact]) {
        self.status = status
        self.contacts = contacts
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus {
        lock.withLock { status }
    }

    func requestAccess() async throws -> ContactsAuthorizationStatus {
        lock.withLock { status }
    }

    func fetchAllContacts() async throws -> [SystemContact] {
        lock.withLock { contacts }
    }
}

private enum ImportInterruption: Error {
    case interrupted
}

private actor InterruptingContactRepository: ContactRepository {
    private var contacts: [Contact] = []
    private let interruptBeforeWrite: Int
    private var writeAttempts = 0

    init(interruptBeforeWrite: Int) {
        self.interruptBeforeWrite = interruptBeforeWrite
    }

    func fetchAll() async throws -> [Contact] {
        contacts
    }

    func fetchTracked() async throws -> [Contact] {
        contacts.filter { $0.tracked && $0.isActive }
    }

    func fetch(id: UUID) async throws -> Contact? {
        contacts.first { $0.id == id }
    }

    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        contacts.filter { $0.contactGroupId == groupId }
    }

    func upsert(_ contact: Contact) async throws {
        writeAttempts += 1
        if writeAttempts == interruptBeforeWrite {
            throw ImportInterruption.interrupted
        }
        contacts.append(contact)
    }

    func archive(id: UUID, at: Date) async throws {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].archivedAt = at
    }
}
