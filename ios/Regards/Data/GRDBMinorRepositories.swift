import Foundation
import GRDB

// The smaller GRDB repository implementations — split out of
// `Repositories.swift` to keep that file under the lint length limit.
// `GRDBContactRepository` (the largest, and the one carrying
// `observeTracked()`/`updateReconciledFields`/`updateLastInteractedAt`)
// stays there.

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

    @discardableResult
    func transitionState(id: UUID, from: ReminderState, to: ReminderState) async throws -> Bool {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE ScheduledReminder SET state = ? WHERE id = ? AND state = ?",
                arguments: [to.rawValue, id.uuidString, from.rawValue])
            return db.changesCount > 0
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
        guard limit > 0 else { return [] }
        return try await dbQueue.read { db in
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
