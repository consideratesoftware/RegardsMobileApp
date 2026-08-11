import Foundation
@testable import Regards

enum ContactWriteTrackingFakeFailure: Error {
    case failed
}

/// A `ContactRepository` that records writes so a test can prove
/// reconciliation/import skipped an unchanged contact rather than writing it
/// through unconditionally.
actor RecordingWriteContactRepository: ContactRepository {
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

/// Fails every `upsert` whose `systemContactRef` is in `failingIdentifiers`,
/// permanently — models a row that keeps failing (e.g. a persistent
/// constraint violation), so per-row tolerance can be proven without
/// aborting the rest of a pass.
actor FailingWriteContactRepository: ContactRepository {
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
            throw ContactWriteTrackingFakeFailure.failed
        }
        contacts[contact.id] = contact
    }
    func archive(id: UUID, at: Date) async throws {
        contacts[id]?.archivedAt = at
    }
}

/// Fails the *first* `upsert` for each identifier in `failOnceForIdentifiers`
/// and succeeds every attempt after — models a transient failure (a lock
/// timeout, a momentary disk error) so a rerun's recovery can be proven
/// distinctly from a permanently-broken row.
actor OnceFailingContactRepository: ContactRepository {
    private var contacts: [UUID: Contact] = [:]
    private var failOnceForIdentifiers: Set<String>

    init(failOnceForIdentifiers: Set<String>) {
        self.failOnceForIdentifiers = failOnceForIdentifiers
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
        if failOnceForIdentifiers.remove(contact.systemContactRef) != nil {
            throw ContactWriteTrackingFakeFailure.failed
        }
        contacts[contact.id] = contact
    }
    func archive(id: UUID, at: Date) async throws {
        contacts[id]?.archivedAt = at
    }
}
