import Foundation
import Testing
import GRDB
@testable import Regards

/// Schema v4 (`ScheduledReminder.firedCycle`, ARCHITECTURE.md §7): fresh
/// creation and upgrades from v1 and v3. Kept apart from
/// `DatabaseMigratorTests` and `DatabaseMigratorV3Tests`.
///
/// v4 adds one nullable column with no default and no backfill. NULL means
/// "no cycle recorded", and that is true of every row written before v4: main
/// never writes a `fired` row, and no build has delivered a notification. So
/// an upgrade must leave every existing row exactly as it was, whatever its
/// kind and state, and the first pass run after it stamps the cycle (TF-07e
/// slice 4).
struct DatabaseMigratorV4Tests {

    // MARK: - Fresh create

    @Test("Fresh latest schema has a nullable firedCycle with no default that is NULL on insert")
    func freshCreateHasANullableFiredCycle() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabase()

        let column = try await queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info('ScheduledReminder')")
                .first { ($0["name"] as String) == "firedCycle" }
                .map { row in
                    (type: row["type"] as String,
                     notNull: row["notnull"] as Int,
                     defaultValue: row["dflt_value"] as String?)
                }
        }
        let found = try #require(column, "ScheduledReminder has no firedCycle column")
        #expect(found.type == "INTEGER")
        #expect(found.notNull == 0)
        #expect(found.defaultValue == nil)

        let seeded = try await seedReminder(in: queue, kind: .cadence, state: .pending, scheduledFor: 1_800_000_000)
        #expect(try await storedReminder(seeded.id, in: queue).firedCycle == nil)
    }

    // MARK: - v3 to v4

    /// Every kind and state is covered: a row of any of them may sit in a v3
    /// store, and none of them belongs to a delivered cycle. The seeded row
    /// carries a stale `snoozedUntil` and an occasion label, so a migration
    /// that rewrote the row would show in another column.
    @Test(
        "v3 row of any kind and state ends with a NULL firedCycle and every other column unchanged",
        arguments: [ReminderKind.cadence, .birthday], ReminderState.allCases
    )
    func v3ToV4LeavesFiredCycleNull(kind: ReminderKind, state: ReminderState) async throws {
        let queue = try DatabaseQueue()
        let migrator = RegardsSchema.migrator()
        try migrator.migrate(queue, upTo: "v3")
        let seeded = try await seedReminder(
            in: queue, kind: kind, state: state, scheduledFor: 1_800_000_100, snoozedUntil: 1_799_996_500)

        try migrator.migrate(queue)

        let stored = try await storedReminder(seeded.id, in: queue)
        #expect(stored.firedCycle == nil)
        #expect(stored == seeded)
    }

    /// v1 and v2 stores skip v3 and v4 until they open on this build. The v3
    /// backfill still gives a pending cadence row its floor, and v4 leaves
    /// that row and a fired occasion row without a cycle.
    @Test("v1 upgrade straight to the latest schema backfills the floor and leaves the cycle NULL")
    func v1UpgradeToLatestBackfillsTheFloorAndLeavesTheCycleNull() async throws {
        let queue = try DatabaseQueue()
        let migrator = RegardsSchema.migrator()
        try migrator.migrate(queue, upTo: "v1")
        let cadence = try await seedReminder(in: queue, kind: .cadence, state: .pending, scheduledFor: 1_800_000_400)
        let birthday = try await seedReminder(in: queue, kind: .birthday, state: .fired, scheduledFor: 1_800_000_500)

        try migrator.migrate(queue)

        var expectedCadence = cadence
        expectedCadence.snoozedUntil = 1_800_000_400
        #expect(try await storedReminder(cadence.id, in: queue) == expectedCadence)
        #expect(try await storedReminder(birthday.id, in: queue) == birthday)
    }

    // MARK: - Later launches

    /// Production builds a fresh migrator on every launch, so this does too.
    /// A later launch must not reset or re-backfill a stored cycle.
    @Test("A second launch's migrate keeps a stored firedCycle")
    func secondMigrateKeepsAStoredCycle() async throws {
        let queue = try DatabaseQueue()
        try RegardsSchema.migrator().migrate(queue)
        let seeded = try await seedReminder(
            in: queue, kind: .cadence, state: .fired, scheduledFor: 1_800_000_600, firedCycle: 1_800_000_000)

        try RegardsSchema.migrator().migrate(queue)

        let stored = try await storedReminder(seeded.id, in: queue)
        #expect(stored.firedCycle == 1_800_000_000)
        #expect(stored == seeded)
    }

    /// The repository reads and writes the column on a store that got it by
    /// upgrade, not only on one created at the latest schema.
    @Test("A row in an upgraded store stores its cycle through the repository")
    func upgradedRowStoresTheCycleThroughTheRepository() async throws {
        let queue = try DatabaseQueue()
        let migrator = RegardsSchema.migrator()
        try migrator.migrate(queue, upTo: "v3")
        let seeded = try await seedReminder(
            in: queue, kind: .cadence, state: .pending, scheduledFor: 1_800_000_700, snoozedUntil: 1_800_000_650)
        try migrator.migrate(queue)
        let reminders = GRDBRepositories(dbQueue: queue).reminders
        let upgraded = try #require(try await reminders.fetchPending(forContact: seeded.contactId).first)
        #expect(upgraded.firedCycle == nil)

        var stamped = upgraded
        stamped.firedCycle = Date(timeIntervalSince1970: 1_800_000_000)
        try await reminders.upsert(stamped)

        let pending = try #require(try await reminders.fetchPending(forContact: seeded.contactId).first)
        #expect(pending.firedCycle == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(pending.snoozedUntil == Date(timeIntervalSince1970: 1_800_000_650))
        #expect(try await storedReminder(seeded.id, in: queue).firedCycle == 1_800_000_000)
    }
}

// MARK: - Fixtures

/// One `ScheduledReminder` row as SQLite stores it, every column. The
/// optional columns are the ones a store might not have yet.
private struct StoredReminder: Equatable {
    var id: String
    var contactId: UUID
    var kind: String
    var occasionDate: String?
    var occasionLabel: String?
    var scheduledFor: Int
    var osNotificationId: String
    var state: String
    var snoozedUntil: Int?
    var firedCycle: Int?
}

/// Inserts a tracked contact and one reminder through raw SQL, naming
/// `snoozedUntil` and `firedCycle` only when given, so it runs against a store
/// that does not have them yet. Returns the row as stored.
private func seedReminder(
    in queue: DatabaseQueue,
    kind: ReminderKind,
    state: ReminderState,
    scheduledFor: Int,
    snoozedUntil: Int? = nil,
    firedCycle: Int? = nil
) async throws -> StoredReminder {
    let isOccasion = kind != .cadence
    let seeded = StoredReminder(
        id: UUID().uuidString,
        contactId: UUID(),
        kind: kind.rawValue,
        occasionDate: isOccasion ? "08-07" : nil,
        occasionLabel: isOccasion ? "Migration occasion" : nil,
        scheduledFor: scheduledFor,
        osNotificationId: "migration-v4",
        state: state.rawValue,
        snoozedUntil: snoozedUntil,
        firedCycle: firedCycle)
    var columns = ["id", "contactId", "kind", "occasionDate", "occasionLabel",
                   "scheduledFor", "osNotificationId", "state"]
    var arguments: [(any DatabaseValueConvertible)?] = [
        seeded.id, seeded.contactId.uuidString, seeded.kind, seeded.occasionDate, seeded.occasionLabel,
        seeded.scheduledFor, seeded.osNotificationId, seeded.state,
    ]
    if let snoozedUntil {
        columns.append("snoozedUntil")
        arguments.append(snoozedUntil)
    }
    if let firedCycle {
        columns.append("firedCycle")
        arguments.append(firedCycle)
    }
    let reminderSQL = "INSERT INTO ScheduledReminder (\(columns.joined(separator: ", "))) "
        + "VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))"
    let reminderArguments = StatementArguments(arguments)
    try await queue.write { db in
        try db.execute(
            sql: """
                INSERT INTO Contact
                    (id, systemContactRef, displayName, tracked, cadenceDays, preferredChannel, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                seeded.contactId.uuidString, "migration-\(seeded.id)", "Migration Contact", true, 14,
                Channel.phoneCall.rawValue, 1_700_000_000,
            ])
        try db.execute(sql: reminderSQL, arguments: reminderArguments)
    }
    return seeded
}

/// Names every column, `firedCycle` included, so a store without the column
/// throws here instead of reading as NULL.
private func storedReminder(_ id: String, in queue: DatabaseQueue) async throws -> StoredReminder {
    try await queue.read { db in
        let row = try #require(try Row.fetchOne(
            db,
            sql: """
                SELECT id, contactId, kind, occasionDate, occasionLabel, scheduledFor,
                       osNotificationId, state, snoozedUntil, firedCycle
                FROM ScheduledReminder WHERE id = ?
                """,
            arguments: [id]))
        return StoredReminder(
            id: row["id"],
            contactId: try #require(UUID(uuidString: row["contactId"])),
            kind: row["kind"],
            occasionDate: row["occasionDate"],
            occasionLabel: row["occasionLabel"],
            scheduledFor: row["scheduledFor"],
            osNotificationId: row["osNotificationId"],
            state: row["state"],
            snoozedUntil: row["snoozedUntil"],
            firedCycle: row["firedCycle"])
    }
}
