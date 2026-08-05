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
    static func failing() -> StubContactRepository {
        StubContactRepository([], failure: RepositoryFakeFailure())
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

    func fetchAllPending() async throws -> [ScheduledReminder] {
        try requireSuccess()
        return reminders
    }

    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder] {
        try requireSuccess()
        return reminders.filter { $0.contactId == contactId }
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
