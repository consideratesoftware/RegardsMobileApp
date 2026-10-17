import Foundation
import Testing
import GRDB
@testable import Regards

/// Schema v3 (`ScheduledReminder.snoozedUntil`, ARCHITECTURE.md §7): fresh
/// creation and upgrades from v1 and v2. Kept apart from
/// `DatabaseMigratorTests`, whose expectations stay untouched and which sits
/// near the file-length limit.
///
/// v2 never stored a snooze floor, and only Snooze wrote a pending cadence
/// row, so the migration backfills `snoozedUntil = scheduledFor` for pending
/// cadence rows and leaves every other row NULL.
struct DatabaseMigratorV3Tests {

    // MARK: - Fresh create

    @Test("Fresh latest schema has a nullable snoozedUntil that defaults to NULL")
    func freshCreateHasSnoozedUntil() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabase()

        let column = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info('ScheduledReminder')")
                .first { ($0["name"] as String) == "snoozedUntil" }
                .map { (type: $0["type"] as String, notNull: $0["notnull"] as Int) }
        }
        let found = try #require(column, "ScheduledReminder has no snoozedUntil column")
        #expect(found.type == "INTEGER")
        #expect(found.notNull == 0)

        let reminderID = UUID().uuidString
        let contactID = UUID().uuidString
        let stored = try await queue.write { db -> Int? in
            try insertContact(db, id: contactID, ref: "fresh-v3")
            try db.execute(
                sql: """
                    INSERT INTO ScheduledReminder
                        (id, contactId, kind, scheduledFor, osNotificationId, state)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    reminderID, contactID, ReminderKind.cadence.rawValue,
                    1_800_000_000, "fresh-v3", ReminderState.pending.rawValue,
                ])
            return try Int.fetchOne(
                db, sql: "SELECT snoozedUntil FROM ScheduledReminder WHERE id = ?",
                arguments: [reminderID])
        }
        #expect(stored == nil)
    }

    // MARK: - v2 to v3 backfill

    @Test("v2 pending cadence row ends with snoozedUntil equal to scheduledFor")
    func v2ToV3BackfillsPendingCadenceSnooze() async throws {
        let queue = try DatabaseQueue()
        let migrator = RegardsSchema.migrator()
        try migrator.migrate(queue, upTo: "v2")
        let id = try await seedReminder(
            in: queue, kind: .cadence, state: .pending, scheduledFor: 1_800_000_100)

        try migrator.migrate(queue)

        #expect(try await storedSnoozedUntil(of: id, in: queue) == 1_800_000_100)
    }

    @Test(
        "v2 pending occasion row keeps a NULL snoozedUntil",
        arguments: [ReminderKind.birthday, .anniversary, .customOccasion]
    )
    func v2ToV3LeavesPendingOccasionNil(kind: ReminderKind) async throws {
        let queue = try DatabaseQueue()
        let migrator = RegardsSchema.migrator()
        try migrator.migrate(queue, upTo: "v2")
        let id = try await seedReminder(
            in: queue, kind: kind, state: .pending, scheduledFor: 1_800_000_200)

        try migrator.migrate(queue)

        #expect(try await storedSnoozedUntil(of: id, in: queue) == nil)
    }

    @Test(
        "v2 cadence row that is not pending keeps a NULL snoozedUntil",
        arguments: [ReminderState.fired, .cancelled, .userCaughtUp]
    )
    func v2ToV3LeavesNonPendingCadenceNil(state: ReminderState) async throws {
        let queue = try DatabaseQueue()
        let migrator = RegardsSchema.migrator()
        try migrator.migrate(queue, upTo: "v2")
        let id = try await seedReminder(
            in: queue, kind: .cadence, state: state, scheduledFor: 1_800_000_300)

        try migrator.migrate(queue)

        #expect(try await storedSnoozedUntil(of: id, in: queue) == nil)
    }

    @Test("v1 upgrade straight to the latest schema backfills a pending cadence row")
    func v1UpgradeBackfillsPendingCadenceSnooze() async throws {
        let queue = try DatabaseQueue()
        let migrator = RegardsSchema.migrator()
        try migrator.migrate(queue, upTo: "v1")
        let id = try await seedReminder(
            in: queue, kind: .cadence, state: .pending, scheduledFor: 1_800_000_400)

        try migrator.migrate(queue)

        #expect(try await storedSnoozedUntil(of: id, in: queue) == 1_800_000_400)
    }

    /// A pending cadence row with a NULL floor is ordinary after v3: the pass
    /// writes one for every contact that is overdue and not snoozed. A
    /// backfill that ran again on a later launch would mark each as snoozed.
    /// Production builds a fresh migrator on every launch, so this does too.
    @Test("A second launch's migrate does not backfill a pending cadence row again")
    func v3DoesNotRebackfillOnSecondMigrate() async throws {
        let queue = try DatabaseQueue()
        try RegardsSchema.migrator().migrate(queue)
        let id = try await seedReminder(
            in: queue, kind: .cadence, state: .pending, scheduledFor: 1_800_000_600)
        #expect(try await storedSnoozedUntil(of: id, in: queue) == nil)

        try RegardsSchema.migrator().migrate(queue)

        #expect(try await storedSnoozedUntil(of: id, in: queue) == nil)
    }

    @Test("Backfill changes only snoozedUntil and the repository reads it back")
    func v2ToV3PreservesRowAndReadsBackThroughRepository() async throws {
        let queue = try DatabaseQueue()
        let migrator = RegardsSchema.migrator()
        try migrator.migrate(queue, upTo: "v2")
        let id = try await seedReminder(
            in: queue, kind: .cadence, state: .pending, scheduledFor: 1_800_000_500)

        try migrator.migrate(queue)

        let pending = try await GRDBRepositories(dbQueue: queue).reminders.fetchAllPending()
        let row = try #require(pending.first { $0.id.uuidString == id })
        #expect(row.kind == .cadence)
        #expect(row.state == .pending)
        #expect(row.scheduledFor == Date(timeIntervalSince1970: 1_800_000_500))
        #expect(row.osNotificationId == "migration-v3")
        #expect(row.snoozedUntil == Date(timeIntervalSince1970: 1_800_000_500))
    }
}

// MARK: - Fixtures

private func insertContact(_ db: Database, id: String, ref: String) throws {
    try db.execute(
        sql: """
            INSERT INTO Contact
                (id, systemContactRef, displayName, tracked, cadenceDays, preferredChannel, createdAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
        arguments: [id, ref, "Migration Contact", true, 14, Channel.phoneCall.rawValue, 1_700_000_000])
}

/// Inserts a contact and one reminder through raw SQL that names no v3
/// column, so it runs against a v1 or v2 database. Returns the reminder id.
private func seedReminder(
    in queue: DatabaseQueue,
    kind: ReminderKind,
    state: ReminderState,
    scheduledFor: Int
) async throws -> String {
    let contactID = UUID().uuidString
    let reminderID = UUID().uuidString
    try await queue.write { db in
        try insertContact(db, id: contactID, ref: "migration-\(reminderID)")
        try db.execute(
            sql: """
                INSERT INTO ScheduledReminder
                    (id, contactId, kind, occasionDate, occasionLabel,
                     scheduledFor, osNotificationId, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                reminderID, contactID, kind.rawValue,
                kind == .cadence ? nil : "08-07",
                kind == .cadence ? nil : "Occasion",
                scheduledFor, "migration-v3", state.rawValue,
            ])
    }
    return reminderID
}

private func storedSnoozedUntil(of reminderID: String, in queue: DatabaseQueue) async throws -> Int? {
    try await queue.read { db in
        try Int.fetchOne(
            db, sql: "SELECT snoozedUntil FROM ScheduledReminder WHERE id = ?",
            arguments: [reminderID])
    }
}
