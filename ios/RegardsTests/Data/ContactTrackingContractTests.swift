import Foundation
import GRDB
import Testing
@testable import Regards

/// TF-11 slice 1: `ContactRepository.updateTracking(id:cadenceDays:)`, the
/// field-scoped write behind the starter picker and its Settings re-entry.
/// It sets `tracked` and `cadenceDays` together and nothing else. A whole-row
/// `upsert` from the picker's snapshot would revert a concurrent reconciler
/// write (§7), and the Settings re-entry runs alongside foreground reconciles.
/// Same parametric-over-`RepositoryContractBackend` shape as
/// `ReminderWindowOverrideContractTests`.
struct ContactTrackingContractTests {
    private static let archivedAt = Date(timeIntervalSince1970: 1_799_999_000)

    /// An untracked, active contact with every other column populated. A write
    /// that drops its `id` filter changes this row and fails the equality check
    /// the callers make. Returns the row as stored.
    private static func seedBystander(_ contacts: any ContactRepository) async throws -> Contact {
        let bystander = contractContact(id: try contractUUID(781), suffix: "tracking-bystander")
        try await contacts.upsert(bystander)
        return try #require(try await contacts.fetch(id: bystander.id))
    }

    @Test(
        "updateTracking tracks the contact at the given cadence and leaves every other column alone",
        arguments: RepositoryContractBackend.allCases
    )
    func updateTrackingWritesOnlyTrackingColumns(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        // `contractContact` seeds name, phones, emails, channel, notes, override,
        // `lastInteractedAt` and `createdAt`, so any of them changing shows up.
        let original = contractContact(id: try contractUUID(782), suffix: "tracking-write")
        try await repositories.contacts.upsert(original)
        let stored = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(!stored.tracked)
        #expect(stored.cadenceDays == nil)
        let bystander = try await Self.seedBystander(repositories.contacts)

        let matched = try await repositories.contacts.updateTracking(id: original.id, cadenceDays: 14)

        #expect(matched)
        let reloaded = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(reloaded.tracked)
        #expect(reloaded.cadenceDays == 14)
        var expected = stored
        expected.tracked = true
        expected.cadenceDays = 14
        #expect(reloaded == expected)
        #expect(try await repositories.contacts.fetch(id: bystander.id) == bystander)
    }

    @Test(
        "updateTracking with a second cadence replaces the first and stays tracked",
        arguments: RepositoryContractBackend.allCases
    )
    func updateTrackingOverwritesExistingCadence(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(id: try contractUUID(783), suffix: "tracking-twice", tracked: true)
        try await repositories.contacts.upsert(original)
        let stored = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(stored.cadenceDays == 14)

        let matched = try await repositories.contacts.updateTracking(id: original.id, cadenceDays: 30)

        #expect(matched)
        let reloaded = try #require(try await repositories.contacts.fetch(id: original.id))
        var expected = stored
        expected.cadenceDays = 30
        #expect(reloaded == expected)
    }

    @Test(
        "updateTracking with nil cadence untracks the contact and clears the cadence",
        arguments: RepositoryContractBackend.allCases
    )
    func updateTrackingNilUntracks(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(id: try contractUUID(784), suffix: "tracking-untrack", tracked: true)
        try await repositories.contacts.upsert(original)
        let stored = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(stored.tracked)
        #expect(stored.cadenceDays == 14)

        let matched = try await repositories.contacts.updateTracking(id: original.id, cadenceDays: nil)

        #expect(matched)
        let reloaded = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(!reloaded.tracked)
        #expect(reloaded.cadenceDays == nil)
        var expected = stored
        expected.tracked = false
        expected.cadenceDays = nil
        #expect(reloaded == expected)
    }

    @Test(
        "updateTracking reports false and writes nothing for an archived contact",
        arguments: RepositoryContractBackend.allCases
    )
    func updateTrackingRefusesArchived(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(
            id: try contractUUID(785),
            suffix: "tracking-archived",
            archivedAt: Self.archivedAt
        )
        try await repositories.contacts.upsert(original)
        let stored = try #require(try await repositories.contacts.fetch(id: original.id))
        let bystander = try await Self.seedBystander(repositories.contacts)

        let matched = try await repositories.contacts.updateTracking(id: original.id, cadenceDays: 14)

        #expect(!matched)
        #expect(try await repositories.contacts.fetch(id: original.id) == stored)
        #expect(try await repositories.contacts.fetch(id: bystander.id) == bystander)
    }

    @Test(
        "updateTracking reports false for an id that matches no row",
        arguments: RepositoryContractBackend.allCases
    )
    func updateTrackingUnknownIdReturnsFalse(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let missingId = try contractUUID(786)
        let bystander = try await Self.seedBystander(repositories.contacts)

        let matched = try await repositories.contacts.updateTracking(id: missingId, cadenceDays: 14)

        #expect(!matched)
        #expect(try await repositories.contacts.fetch(id: missingId) == nil)
        #expect(try await repositories.contacts.fetch(id: bystander.id) == bystander)
    }

    /// The invariant is `tracked == (cadenceDays != nil)` with `cadenceDays >= 1`.
    /// A zero or negative cadence throws before anything is written.
    @Test(
        "updateTracking throws for a cadence below 1 and leaves the stored row unchanged",
        arguments: RepositoryContractBackend.allCases, [0, -1]
    )
    func updateTrackingRejectsZeroCadence(backend: RepositoryContractBackend, cadenceDays: Int) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(id: try contractUUID(787), suffix: "tracking-invalid")
        try await repositories.contacts.upsert(original)
        let stored = try #require(try await repositories.contacts.fetch(id: original.id))
        let bystander = try await Self.seedBystander(repositories.contacts)

        await #expect(throws: ContactTrackingError.invalidCadenceDays(cadenceDays)) {
            try await repositories.contacts.updateTracking(id: original.id, cadenceDays: cadenceDays)
        }

        #expect(try await repositories.contacts.fetch(id: original.id) == stored)
        #expect(try await repositories.contacts.fetch(id: bystander.id) == bystander)
    }

    /// Ordering check only: a reconciled name written after the picker's
    /// snapshot is still there after the tracking write. This catches an
    /// implementation that writes back a row it read before the call; it cannot
    /// catch a read-then-upsert done inside the method, because that reads the
    /// row after `updateReconciledFields` has landed.
    /// `grdbWriteTouchesOnlyTheTrackingColumns` below is the field-scope proof.
    @Test(
        "updateTracking keeps a reconciled name written after the caller's snapshot",
        arguments: RepositoryContractBackend.allCases
    )
    func updateTrackingKeepsConcurrentReconciledName(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(id: try contractUUID(788), suffix: "tracking-race")
        try await repositories.contacts.upsert(original)
        let snapshot = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(snapshot.displayName != "Renamed By Reconcile")

        try await repositories.contacts.updateReconciledFields(
            id: original.id,
            fields: ReconciledContactFields(
                displayName: "Renamed By Reconcile",
                phoneNumbers: snapshot.phoneNumbers,
                emailAddresses: snapshot.emailAddresses,
                preferredChannelValue: snapshot.preferredChannelValue,
                archivedAt: nil
            )
        )
        let matched = try await repositories.contacts.updateTracking(id: snapshot.id, cadenceDays: 7)

        #expect(matched)
        let reloaded = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(reloaded.displayName == "Renamed By Reconcile")
        #expect(reloaded.tracked)
        #expect(reloaded.cadenceDays == 7)
    }

    /// The field-scope proof. Triggers on `main.Contact` abort every way of
    /// rewriting the row except a plain `UPDATE` of `tracked` and `cadenceDays`:
    /// an `UPDATE` naming any other column (the column list comes from the live
    /// table, so a column added later is covered), an `UPDATE` of the rowid, any
    /// `INSERT` (including `INSERT OR REPLACE`, which deletes the old row and
    /// cascades into the contact's history), and any `DELETE`. A
    /// fetch-then-`upsert`, a delete-then-insert and a replace-insert all fail
    /// here; the two-column `UPDATE` succeeds and the contact's InteractionLog
    /// and ScheduledReminder rows survive.
    @Test("GRDB tracking write sets only the tracked and cadenceDays columns")
    func grdbWriteTouchesOnlyTheTrackingColumns() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabase()
        let repositories = GRDBRepositories(dbQueue: dbQueue)
        let contacts = repositories.contacts
        let original = contractContact(id: try contractUUID(789), suffix: "tracking-column-scope")
        try await contacts.upsert(original)
        let log = InteractionLog(
            id: try contractUUID(790),
            contactId: original.id,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: .manual
        )
        let reminder = ScheduledReminder(
            id: try contractUUID(791),
            contactId: original.id,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_100),
            osNotificationId: "tracking-column-scope"
        )
        try await repositories.interactions.append(log)
        try await repositories.reminders.upsert(reminder)
        let bystander = try await Self.seedBystander(contacts)

        try await dbQueue.write { db in
            let others = try Row.fetchAll(db, sql: "PRAGMA table_info(Contact)")
                .map { $0["name"] as String }
                .filter { $0 != "tracked" && $0 != "cadenceDays" }
            #expect(others.count > 10)
            let columns = (others + ["rowid", "_rowid_", "oid"]).map { "\"\($0)\"" }.joined(separator: ", ")
            try db.execute(sql: """
                CREATE TRIGGER main.trackingScopeUpdate BEFORE UPDATE OF \(columns) ON Contact
                BEGIN SELECT RAISE(ABORT, 'tracking-scope:update'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER main.trackingScopeInsert BEFORE INSERT ON Contact
                BEGIN SELECT RAISE(ABORT, 'tracking-scope:insert'); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER main.trackingScopeDelete BEFORE DELETE ON Contact
                BEGIN SELECT RAISE(ABORT, 'tracking-scope:delete'); END
                """)
        }

        // Each probe must be refused by its own trigger, so a trigger that
        // does not bite fails here instead of silently weakening the proof.
        let probes: [(sql: String, message: String)] = [
            ("UPDATE Contact SET displayName = displayName", "tracking-scope:update"),
            ("UPDATE Contact SET rowid = rowid", "tracking-scope:update"),
            ("INSERT OR REPLACE INTO Contact SELECT * FROM Contact WHERE id = ?", "tracking-scope:insert"),
            ("DELETE FROM Contact WHERE id = ?", "tracking-scope:delete"),
        ]
        for probe in probes {
            do {
                try await dbQueue.write { db in
                    try db.execute(
                        sql: probe.sql,
                        arguments: probe.sql.contains("?") ? [original.id.uuidString] : []
                    )
                }
                Issue.record("Expected '\(probe.sql)' to be refused")
            } catch let error as DatabaseError {
                #expect(error.message == probe.message, "\(probe.sql)")
            }
        }

        let matched = try await contacts.updateTracking(id: original.id, cadenceDays: 14)

        #expect(matched)
        let reloaded = try #require(try await contacts.fetch(id: original.id))
        #expect(reloaded.tracked)
        #expect(reloaded.cadenceDays == 14)
        #expect(try await contacts.fetch(id: bystander.id) == bystander)
        let logs = try await repositories.interactions.fetchRecent(forContact: original.id, limit: 10)
        let reminders = try await repositories.reminders.fetchPending(forContact: original.id)
        #expect(logs.map(\.id) == [log.id])
        #expect(reminders.map(\.id) == [reminder.id])
    }

    /// Upcoming and Overdue rebuild their rows from `observeTracked()`. A
    /// field-scoped write that forgets to broadcast leaves a freshly picked
    /// starter out of both lists until the next unrelated write (the same
    /// parity gap `ContactObservationContractTests` pins for the other
    /// field-scoped writes). GRDB observes the region on its own; the mock has
    /// to broadcast explicitly.
    @Test(
        "observeTracked emits the contact after updateTracking tracks it",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func observeTrackedEmitsOnTrackingWrite(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contactID = try contractUUID(792)
        try await repositories.contacts.upsert(contractContact(id: contactID, suffix: "tracking-observed"))
        let stream = await repositories.contacts.observeTracked()
        var iterator = stream.makeAsyncIterator()

        _ = try await repositories.contacts.updateTracking(id: contactID, cadenceDays: 14)

        let emitted = try #require(await iterator.next())
        let observed = try #require(emitted.first { $0.id == contactID })
        #expect(observed.cadenceDays == 14)
    }

    // MARK: - Decision #29 with a late tracking write

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// Pins today's behavior, which owner ruling 6 accepted: tracking writes
    /// neither `lastInteractedAt` nor a tracked-since date, so a contact imported
    /// 100 days ago and tracked today anchors on its `createdAt` and is already
    /// 86 days overdue at a 14-day cadence. A later change that stamps an anchor
    /// at tracking time (the tracked-since R-item, owned by TF-09) must change
    /// this test on purpose.
    @Test(
        "A contact imported long ago and tracked now keeps its createdAt anchor and shows as overdue",
        arguments: RepositoryContractBackend.allCases
    )
    @MainActor
    func trackingOldImportAnchorsAtCreatedAt(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let importedAt = Self.now.addingTimeInterval(-100 * 86_400)
        let oldImport = Contact(
            id: try contractUUID(793),
            systemContactRef: "repository-contract-tracking-old-import",
            displayName: "Old Import",
            preferredChannel: .phoneCall,
            preferredChannelValue: "+14155550100",
            phoneNumbers: ["+14155550100"],
            lastInteractedAt: nil,
            createdAt: importedAt
        )
        try await repositories.contacts.upsert(oldImport)

        let matched = try await repositories.contacts.updateTracking(id: oldImport.id, cadenceDays: 14)

        #expect(matched)
        let reloaded = try #require(try await repositories.contacts.fetch(id: oldImport.id))
        #expect(reloaded.lastInteractedAt == nil)
        #expect(reloaded.createdAt == importedAt)
        let row = try #require(
            OverdueViewModel.makeOverdueRow(for: reloaded, now: Self.now, calendar: Self.utcCalendar)
        )
        #expect(row.overdueDays == 86)
    }
}
