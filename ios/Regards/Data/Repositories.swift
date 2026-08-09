import Foundation
import GRDB

// Repository protocols — the "seam" the UI layer depends on. GRDB
// implementations live immediately below; PR3 will inject a `MockRepositories`
// instance that satisfies the same protocols so the UI shell can render
// against seeded data.

public protocol ContactRepository: Sendable {
    func fetchAll() async throws -> [Contact]
    func fetchTracked() async throws -> [Contact]
    func fetch(id: UUID) async throws -> Contact?
    /// Returns every contact whose `contactGroupId` matches `groupId`,
    /// **including archived members**. ContactGroup is a virtual merge target
    /// (ARCHITECTURE.md §7); archival is a contact-level concept and does not
    /// silently change group membership. Callers that want active-only
    /// members filter on `isActive` themselves.
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact]
    func upsert(_ contact: Contact) async throws
    func archive(id: UUID, at: Date) async throws
}

public protocol ContactGroupRepository: Sendable {
    func fetchAll() async throws -> [ContactGroup]
    func fetch(id: UUID) async throws -> ContactGroup?
    func upsert(_ group: ContactGroup) async throws
    /// Deletes the virtual group and clears `contactGroupId` on every member.
    func delete(id: UUID) async throws
}

public protocol ReminderRepository: Sendable {
    /// Pending reminders ordered by `scheduledFor`, then `id`, ascending.
    func fetchAllPending() async throws -> [ScheduledReminder]
    /// The contact's pending reminders ordered by `scheduledFor`, then `id`, ascending.
    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder]
    func upsert(_ reminder: ScheduledReminder) async throws
    func updateState(id: UUID, state: ReminderState) async throws
    func delete(id: UUID) async throws
}

public protocol InteractionRepository: Sendable {
    /// The contact's logs ordered by `occurredAt` descending, then `id` ascending.
    func fetchRecent(forContact contactId: UUID, limit: Int) async throws -> [InteractionLog]
    func append(_ log: InteractionLog) async throws
}

public protocol ReminderWindowRepository: Sendable {
    func fetchGlobal() async throws -> ReminderWindow
    /// Validates the window before replacing the persisted singleton.
    func saveGlobal(_ window: ReminderWindow) async throws
}

public protocol UserProfileRepository: Sendable {
    func fetch() async throws -> UserProfile
    func save(_ profile: UserProfile) async throws
}

// MARK: - GRDB implementations

/// Bag-of-repositories backed by a single GRDB `DatabaseQueue`. Production
/// code owns one instance of this; tests swap in `MockRepositories` at the
/// protocol seam.
public struct GRDBRepositories: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public var contacts: any ContactRepository { GRDBContactRepository(dbQueue: dbQueue) }
    public var groups: any ContactGroupRepository { GRDBContactGroupRepository(dbQueue: dbQueue) }
    public var reminders: any ReminderRepository { GRDBReminderRepository(dbQueue: dbQueue) }
    public var interactions: any InteractionRepository { GRDBInteractionRepository(dbQueue: dbQueue) }
    public var window: any ReminderWindowRepository { GRDBReminderWindowRepository(dbQueue: dbQueue) }
    public var profile: any UserProfileRepository { GRDBUserProfileRepository(dbQueue: dbQueue) }
}

struct GRDBContactRepository: ContactRepository {
    let dbQueue: DatabaseQueue

    func fetchAll() async throws -> [Contact] {
        try await dbQueue.read { db in
            try ContactRecord.fetchAll(db).map { try $0.toDomain() }
        }
    }

    func fetchTracked() async throws -> [Contact] {
        try await dbQueue.read { db in
            try ContactRecord
                .filter(Column("tracked") == true && Column("archivedAt") == nil)
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func fetch(id: UUID) async throws -> Contact? {
        try await dbQueue.read { db in
            try ContactRecord.fetchOne(db, key: id.uuidString).map { try $0.toDomain() }
        }
    }

    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        try await dbQueue.read { db in
            try ContactRecord
                .filter(Column("contactGroupId") == groupId.uuidString)
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func upsert(_ contact: Contact) async throws {
        let record = try ContactRecord(from: contact)
        try await dbQueue.write { db in
            try record.save(db)
        }
    }

    /// Stamps `archivedAt` as integer epoch seconds. Sub-second precision on
    /// the input `Date` is dropped silently; the schema stores every Date
    /// column the same way (see `Records.swift` and ARCHITECTURE.md §7).
    func archive(id: UUID, at: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE Contact SET archivedAt = ? WHERE id = ?",
                arguments: [Int(at.timeIntervalSince1970), id.uuidString])
        }
    }
}

struct GRDBContactGroupRepository: ContactGroupRepository {
    let dbQueue: DatabaseQueue

    func fetchAll() async throws -> [ContactGroup] {
        try await dbQueue.read { db in
            try ContactGroupRecord.fetchAll(db).map { try $0.toDomain() }
        }
    }

    func fetch(id: UUID) async throws -> ContactGroup? {
        try await dbQueue.read { db in
            try ContactGroupRecord.fetchOne(db, key: id.uuidString).map { try $0.toDomain() }
        }
    }

    func upsert(_ group: ContactGroup) async throws {
        let record = ContactGroupRecord(from: group)
        try await dbQueue.write { db in try record.save(db) }
    }

    func delete(id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE Contact SET contactGroupId = NULL WHERE contactGroupId = ?",
                arguments: [id.uuidString])
            _ = try ContactGroupRecord.deleteOne(db, key: id.uuidString)
        }
    }
}

struct GRDBReminderRepository: ReminderRepository {
    let dbQueue: DatabaseQueue

    func fetchAllPending() async throws -> [ScheduledReminder] {
        try await dbQueue.read { db in
            try ScheduledReminderRecord
                .filter(Column("state") == ReminderState.pending.rawValue)
                .order(Column("scheduledFor"), Column("id"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder] {
        try await dbQueue.read { db in
            try ScheduledReminderRecord
                .filter(Column("contactId") == contactId.uuidString
                        && Column("state") == ReminderState.pending.rawValue)
                .order(Column("scheduledFor"), Column("id"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func upsert(_ reminder: ScheduledReminder) async throws {
        let record = ScheduledReminderRecord(from: reminder)
        try await dbQueue.write { db in try record.save(db) }
    }

    func updateState(id: UUID, state: ReminderState) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE ScheduledReminder SET state = ? WHERE id = ?",
                arguments: [state.rawValue, id.uuidString])
        }
    }

    func delete(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try ScheduledReminderRecord.deleteOne(db, key: id.uuidString)
        }
    }
}

struct GRDBInteractionRepository: InteractionRepository {
    let dbQueue: DatabaseQueue

    func fetchRecent(forContact contactId: UUID, limit: Int) async throws -> [InteractionLog] {
        try await dbQueue.read { db in
            try InteractionLogRecord
                .filter(Column("contactId") == contactId.uuidString)
                .order(Column("occurredAt").desc, Column("id"))
                .limit(limit)
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func append(_ log: InteractionLog) async throws {
        let record = InteractionLogRecord(from: log)
        try await dbQueue.write { db in try record.insert(db) }
    }
}

struct GRDBReminderWindowRepository: ReminderWindowRepository {
    let dbQueue: DatabaseQueue

    func fetchGlobal() async throws -> ReminderWindow {
        try await dbQueue.read { db in
            guard let rec = try ReminderWindowRecord.fetchOne(db, key: 1) else {
                throw DataError.notFound
            }
            return try rec.toDomain()
        }
    }

    func saveGlobal(_ window: ReminderWindow) async throws {
        try window.validate()
        let record = try ReminderWindowRecord(from: window)
        try await dbQueue.write { db in try record.save(db) }
    }
}

struct GRDBUserProfileRepository: UserProfileRepository {
    let dbQueue: DatabaseQueue

    func fetch() async throws -> UserProfile {
        try await dbQueue.read { db in
            guard let rec = try UserProfileRecord.fetchOne(db, key: 1) else {
                throw DataError.notFound
            }
            return rec.toDomain()
        }
    }

    func save(_ profile: UserProfile) async throws {
        let record = UserProfileRecord(from: profile)
        try await dbQueue.write { db in try record.save(db) }
    }
}
