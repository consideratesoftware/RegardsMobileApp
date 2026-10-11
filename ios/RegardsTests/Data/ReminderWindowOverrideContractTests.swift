import Foundation
import GRDB
import Testing
@testable import Regards

/// TF-05 slice 1: `ContactRepository.updateReminderWindowOverride(id:window:)`,
/// the field-scoped write behind the per-contact window editor. A whole-row
/// `upsert` from a Contact Detail snapshot would revert any `lastInteractedAt`
/// or reconciler write that landed after the snapshot was taken (§7), so the
/// method writes the one column and nothing else. Same parametric-over-
/// `RepositoryContractBackend` shape as `UpdateLastInteractedAtContractTests`.
struct ReminderWindowOverrideContractTests {
    private static let saturdayMorning = ReminderWindow(
        allowedDays: .saturday,
        allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12))],
        timezoneIdentifier: "Etc/UTC"
    )

    @Test(
        "updateReminderWindowOverride stores the window, reports a match, and leaves every other field alone",
        arguments: RepositoryContractBackend.allCases
    )
    func writesWindowAndRoundTrips(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(id: try contractUUID(171), suffix: "override-write", tracked: true)
        try await repositories.contacts.upsert(original)
        let stored = try #require(try await repositories.contacts.fetch(id: original.id))
        let window = Self.saturdayMorning

        let matched = try await repositories.contacts.updateReminderWindowOverride(id: original.id, window: window)

        #expect(matched)
        let reloaded = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(reloaded.reminderWindowOverride == window)
        var expected = stored
        expected.reminderWindowOverride = window
        #expect(reloaded == expected)
    }

    @Test(
        "updateReminderWindowOverride with nil clears the override",
        arguments: RepositoryContractBackend.allCases
    )
    func nilClearsOverride(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        // The fixture starts with a non-nil override, so a no-op write fails this.
        let original = contractContact(id: try contractUUID(172), suffix: "override-clear", tracked: true)
        try await repositories.contacts.upsert(original)
        #expect(try await repositories.contacts.fetch(id: original.id)?.reminderWindowOverride != nil)

        let matched = try await repositories.contacts.updateReminderWindowOverride(id: original.id, window: nil)

        #expect(matched)
        let reloaded = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(reloaded.reminderWindowOverride == nil)
    }

    /// R39: "Use my default window" must store SQL NULL. A JSON encoder
    /// handed an optional can write the four-character text `null` instead,
    /// which decodes as "no override" today but is a different stored shape
    /// than every other no-override row.
    @Test("GRDB stores SQL NULL, not the text 'null', when the override is cleared")
    func grdbClearWritesSQLNull() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabase()
        let contacts = GRDBRepositories(dbQueue: dbQueue).contacts
        let original = contractContact(id: try contractUUID(173), suffix: "override-sql-null", tracked: true)
        try await contacts.upsert(original)

        _ = try await contacts.updateReminderWindowOverride(id: original.id, window: nil)

        let row = try await dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT typeof(reminderWindowOverride) AS kind FROM Contact WHERE id = ?",
                arguments: [original.id.uuidString]
            )
        }
        let kind: String? = row?["kind"]
        #expect(kind == "null")
    }

    /// Ordering check only: a `lastInteractedAt` written after the caller's
    /// snapshot is still there after the override write. This catches an
    /// implementation that writes back a row it read before the call; it
    /// cannot catch a read-then-upsert done inside the method, because that
    /// reads the row after `updateLastInteractedAt` has landed.
    /// `grdbWriteTouchesOnlyTheOverrideColumn` below is the field-scope proof.
    @Test(
        "updateReminderWindowOverride keeps a lastInteractedAt written after the caller's snapshot",
        arguments: RepositoryContractBackend.allCases
    )
    func laterOverrideWriteKeepsEarlierLastInteractedAt(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(id: try contractUUID(174), suffix: "override-race", tracked: true)
        try await repositories.contacts.upsert(original)
        let snapshot = try #require(try await repositories.contacts.fetch(id: original.id))
        let newer = Date(timeIntervalSince1970: 1_800_000_500)
        #expect(snapshot.lastInteractedAt != newer)

        _ = try await repositories.contacts.updateLastInteractedAt(id: original.id, at: newer)
        let matched = try await repositories.contacts.updateReminderWindowOverride(
            id: snapshot.id,
            window: Self.saturdayMorning
        )

        #expect(matched)
        let reloaded = try #require(try await repositories.contacts.fetch(id: original.id))
        #expect(reloaded.lastInteractedAt == newer)
        #expect(reloaded.reminderWindowOverride == Self.saturdayMorning)
    }

    /// The field-scope proof. A temp trigger aborts any `UPDATE` whose SET
    /// list names a Contact column other than `reminderWindowOverride`, so a
    /// fetch-then-`upsert` (which sets every column) fails here while the
    /// single-column `UPDATE` succeeds. The column list comes from the live
    /// table, so a column added later is covered without touching this test.
    @Test("GRDB override write sets only the reminderWindowOverride column")
    func grdbWriteTouchesOnlyTheOverrideColumn() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabase()
        let contacts = GRDBRepositories(dbQueue: dbQueue).contacts
        let original = contractContact(id: try contractUUID(179), suffix: "override-column-scope", tracked: true)
        try await contacts.upsert(original)
        try await dbQueue.write { db in
            let others = try Row.fetchAll(db, sql: "PRAGMA table_info(Contact)")
                .map { $0["name"] as String }
                .filter { $0 != "reminderWindowOverride" }
            #expect(others.count > 10)
            let columns = others.map { "\"\($0)\"" }.joined(separator: ", ")
            try db.execute(sql: """
                CREATE TEMP TRIGGER overrideFieldScope BEFORE UPDATE OF \(columns) ON Contact
                BEGIN SELECT RAISE(ABORT, 'field-scope violated'); END
                """)
        }
        // The probe must bite: a whole-row write is refused.
        await expectWriteRejected { try await contacts.upsert(original) }

        let matched = try await contacts.updateReminderWindowOverride(id: original.id, window: Self.saturdayMorning)

        #expect(matched)
        #expect(try await contacts.fetch(id: original.id)?.reminderWindowOverride == Self.saturdayMorning)
    }

    /// Validation runs before the row lookup, so an invalid window throws
    /// even when the id would have reported `false`.
    @Test(
        "updateReminderWindowOverride throws for an invalid window even when the id is missing or archived",
        arguments: RepositoryContractBackend.allCases
    )
    func invalidWindowThrowsEvenForMissingOrArchivedId(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let archived = contractContact(
            id: try contractUUID(180),
            suffix: "override-invalid-archived",
            tracked: true,
            archivedAt: Date(timeIntervalSince1970: 1_799_999_000)
        )
        try await repositories.contacts.upsert(archived)
        let wrapping = TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 1))
        let invalid = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [wrapping],
            timezoneIdentifier: "Etc/UTC"
        )

        await #expect(throws: ReminderWindow.ValidationError.wrappingAllowedRange(wrapping)) {
            try await repositories.contacts.updateReminderWindowOverride(
                id: try contractUUID(181),
                window: invalid
            )
        }
        await #expect(throws: ReminderWindow.ValidationError.wrappingAllowedRange(wrapping)) {
            try await repositories.contacts.updateReminderWindowOverride(id: archived.id, window: invalid)
        }
    }

    @Test(
        "updateReminderWindowOverride rejects a wrapping allowed range and leaves the stored row unchanged",
        arguments: RepositoryContractBackend.allCases
    )
    func wrappingAllowedRangeThrowsAndWritesNothing(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(id: try contractUUID(175), suffix: "override-wrap", tracked: true)
        try await repositories.contacts.upsert(original)
        let stored = try #require(try await repositories.contacts.fetch(id: original.id))
        let wrapping = TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 1))
        let invalid = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [wrapping],
            timezoneIdentifier: "Etc/UTC"
        )

        await #expect(throws: ReminderWindow.ValidationError.wrappingAllowedRange(wrapping)) {
            try await repositories.contacts.updateReminderWindowOverride(id: original.id, window: invalid)
        }

        #expect(try await repositories.contacts.fetch(id: original.id) == stored)
    }

    @Test(
        "updateReminderWindowOverride reports false for an id that matches no row",
        arguments: RepositoryContractBackend.allCases
    )
    func reportsFalseForMissingId(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let missingId = try contractUUID(176)

        let matched = try await repositories.contacts.updateReminderWindowOverride(
            id: missingId,
            window: Self.saturdayMorning
        )

        #expect(!matched)
        #expect(try await repositories.contacts.fetch(id: missingId) == nil)
    }

    @Test(
        "updateReminderWindowOverride reports false and writes nothing for an archived contact",
        arguments: RepositoryContractBackend.allCases
    )
    func reportsFalseForArchivedContact(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let original = contractContact(
            id: try contractUUID(177),
            suffix: "override-archived",
            tracked: true,
            archivedAt: Date(timeIntervalSince1970: 1_799_999_000)
        )
        try await repositories.contacts.upsert(original)
        let stored = try #require(try await repositories.contacts.fetch(id: original.id))

        let matched = try await repositories.contacts.updateReminderWindowOverride(
            id: original.id,
            window: Self.saturdayMorning
        )

        #expect(!matched)
        #expect(try await repositories.contacts.fetch(id: original.id) == stored)
    }

    /// Upcoming rebuilds its rows from `observeTracked()`. A field-scoped
    /// write that forgets to broadcast leaves the row at its old time until
    /// the next unrelated write (the same parity gap the sibling tests in
    /// `ContactObservationContractTests` pin for the other field-scoped writes).
    @Test(
        "observeTracked emits the new override after updateReminderWindowOverride",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func observeTrackedEmitsOnOverrideWrite(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contactID = try contractUUID(178)
        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "override-observed", tracked: true)
        )
        let stream = await repositories.contacts.observeTracked()
        var iterator = stream.makeAsyncIterator()

        _ = try await repositories.contacts.updateReminderWindowOverride(id: contactID, window: Self.saturdayMorning)

        let emitted = try #require(await iterator.next())
        let observed = try #require(emitted.first { $0.id == contactID })
        #expect(observed.reminderWindowOverride == Self.saturdayMorning)
    }
}
