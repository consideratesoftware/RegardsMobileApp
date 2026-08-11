import Foundation
@testable import Regards

/// Shared in-memory repository fakes for unit tests.
///
/// These replace the per-file `Boundary*`/`Static*` copies that had drifted
/// into method-for-method duplicates (TF-01 hygiene). One fake per protocol,
/// each able to serve a fixed dataset or fail every read, so failure paths are
/// as cheap to drive as success paths.

/// The error a failing fake throws. Deliberately opaque: call sites assert on
/// the view model's resulting state, never on the error's identity.
struct RepositoryFakeFailure: Error, Equatable {}

actor StubContactRepository: ContactRepository {
    private let contacts: [Contact]
    private let failure: RepositoryFakeFailure?

    init(_ contacts: [Contact] = [], failure: RepositoryFakeFailure? = nil) {
        self.contacts = contacts
        self.failure = failure
    }

    /// A repository whose every read throws.
    static func failing(_ contacts: [Contact] = []) -> StubContactRepository {
        StubContactRepository(contacts, failure: RepositoryFakeFailure())
    }

    private func requireSuccess() throws {
        if let failure { throw failure }
    }

    func fetchAll() async throws -> [Contact] {
        try requireSuccess()
        return contacts
    }

    /// Mirrors both production implementations: `tracked == true` **and**
    /// `archivedAt == nil`. The GRDB repository filters on both columns and
    /// `MockStore.tracked()` does the same. Filtering on `tracked` alone here
    /// would let an archived-but-tracked contact keep rows in every
    /// fake-driven test — exactly the mock/production drift R23 exists to
    /// prevent, and this fake now backs the whole Upcoming suite.
    func fetchTracked() async throws -> [Contact] {
        try requireSuccess()
        return contacts.filter { $0.tracked && $0.archivedAt == nil }
    }

    func fetch(id: UUID) async throws -> Contact? {
        try requireSuccess()
        return contacts.first { $0.id == id }
    }

    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        try requireSuccess()
        return contacts.filter { $0.contactGroupId == groupId }
    }

    func upsert(_ contact: Contact) async throws {
        try requireSuccess()
    }

    func archive(id: UUID, at: Date) async throws {
        try requireSuccess()
    }

    func storedCount() -> Int { contacts.count }
}

/// A `ContactRepository` whose backing `ContactFetchReport` (healthy
/// contacts plus corruption diagnostics) can be replaced after
/// construction — for tests that mutate the store mid-test to simulate
/// what a completed reconciliation pass, a newly-discovered corrupt row, or
/// a fresh import would produce, then assert a view model or screen reacts
/// through its real observation path rather than a direct reload call. A
/// fixed report that's never replaced works too (just don't call
/// `setReport`/`replaceContacts`), so this also covers what a `Stub`-style
/// fixed fake would have needed. Consolidates three near-identical
/// single-call-site fakes (`MutableAllContactsRepository`,
/// `MutableDiagnosticsRepository`, `FixedDiagnosticsRepository`) that had
/// accumulated one per test file across TF-03.
actor SettableContactRepository: ContactRepository {
    private var report: ContactFetchReport

    init(contacts: [Contact] = [], corrupted: [ContactCorruptionDiagnostic] = []) {
        self.report = ContactFetchReport(contacts: contacts, corrupted: corrupted)
    }

    init(report: ContactFetchReport) {
        self.report = report
    }

    func fetchAll() async throws -> [Contact] { report.contacts }
    func fetchTracked() async throws -> [Contact] {
        report.contacts.filter { $0.tracked && $0.isActive }
    }
    func fetch(id: UUID) async throws -> Contact? { report.contacts.first { $0.id == id } }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        report.contacts.filter { $0.contactGroupId == groupId }
    }
    func upsert(_ contact: Contact) async throws {
        report = ContactFetchReport(contacts: report.contacts + [contact], corrupted: report.corrupted)
    }
    func archive(id: UUID, at: Date) async throws {}
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport { report }

    /// Replaces the healthy contacts, leaving the current corruption
    /// diagnostics untouched.
    func replaceContacts(_ newContacts: [Contact]) {
        report = ContactFetchReport(contacts: newContacts, corrupted: report.corrupted)
    }

    /// Replaces the entire report — contacts and diagnostics both.
    func setReport(_ newReport: ContactFetchReport) {
        report = newReport
    }
}

actor StubReminderRepository: ReminderRepository {
    private let reminders: [ScheduledReminder]
    private let failure: RepositoryFakeFailure?

    init(_ reminders: [ScheduledReminder] = [], failure: RepositoryFakeFailure? = nil) {
        self.reminders = reminders
        self.failure = failure
    }

    /// A repository whose every read throws.
    static func failing() -> StubReminderRepository {
        StubReminderRepository([], failure: RepositoryFakeFailure())
    }

    private func requireSuccess() throws {
        if let failure { throw failure }
    }

    /// Mirrors both production implementations, which filter on
    /// `state == .pending`. Returning every reminder regardless of state would
    /// let a fired, cancelled, or caught-up reminder keep a row in Upcoming
    /// throughout the fake-driven suite while production quietly excludes it
    /// (R23 mock/production drift).
    func fetchAllPending() async throws -> [ScheduledReminder] {
        try requireSuccess()
        return reminders.filter { $0.state == .pending }
    }

    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder] {
        try requireSuccess()
        return reminders.filter { $0.contactId == contactId && $0.state == .pending }
    }

    func upsert(_ reminder: ScheduledReminder) async throws {
        try requireSuccess()
    }

    func updateState(id: UUID, state: ReminderState) async throws {
        try requireSuccess()
    }

    func delete(id: UUID) async throws {
        try requireSuccess()
    }
}

struct StubReminderWindowRepository: ReminderWindowRepository {
    enum ReadFailure: Sendable {
        case opaque
        case missing
        case invalidTimezone(String)
    }

    let failure: ReadFailure

    static func failing() -> StubReminderWindowRepository {
        StubReminderWindowRepository(failure: .opaque)
    }

    static func missing() -> StubReminderWindowRepository {
        StubReminderWindowRepository(failure: .missing)
    }

    static func invalidTimezone(_ identifier: String) -> StubReminderWindowRepository {
        StubReminderWindowRepository(failure: .invalidTimezone(identifier))
    }

    func fetchGlobal() async throws -> ReminderWindow {
        switch failure {
        case .opaque:
            throw RepositoryFakeFailure()
        case .missing:
            throw DataError.notFound
        case let .invalidTimezone(identifier):
            throw ReminderWindow.ValidationError.invalidTimezoneIdentifier(identifier)
        }
    }

    func saveGlobal(_ window: ReminderWindow) async throws {}
}
