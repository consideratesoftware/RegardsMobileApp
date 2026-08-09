import GRDB
import Testing
@testable import Regards

extension SingletonRepositoryContractTests {
    @Test("GRDB ReminderWindow reads reject a missing persisted singleton")
    func grdbReminderWindowReadRejectsMissingSingleton() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        try await database.write { db in
            try db.execute(sql: "DELETE FROM ReminderWindow WHERE id = 1")
        }
        let repository = GRDBRepositories(dbQueue: database).window

        do {
            _ = try await repository.fetchGlobal()
            Issue.record("Expected fetchGlobal to reject a missing singleton")
        } catch DataError.notFound {
            // Expected. AppRuntime surfaces this as a recoverable launch failure.
        } catch {
            Issue.record("Expected DataError.notFound, got \(error)")
        }
    }

    @Test("GRDB ReminderWindow reads reject an invalid persisted timezone")
    func grdbReminderWindowReadRejectsInvalidTimezone() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        try await database.write { db in
            try db.execute(
                sql: "UPDATE ReminderWindow SET timezone = ? WHERE id = 1",
                arguments: ["Not/A_Timezone"]
            )
        }
        let repository = GRDBRepositories(dbQueue: database).window

        do {
            _ = try await repository.fetchGlobal()
            Issue.record("Expected fetchGlobal to reject an invalid timezone")
        } catch ReminderWindow.ValidationError.invalidTimezoneIdentifier("Not/A_Timezone") {
            // Expected. Corrupt timing must not silently fall back to the device zone.
        } catch {
            Issue.record("Expected invalidTimezoneIdentifier, got \(error)")
        }
    }

    @Test(
        "ReminderWindow reads reject a corrupt stored singleton",
        arguments: RepositoryContractBackend.allCases
    )
    func reminderWindowReadValidation(backend: RepositoryContractBackend) async throws {
        let repository: any ReminderWindowRepository
        switch backend {
        case .mock:
            let invalid = ReminderWindow(
                allowedDays: .allDays,
                allowedTimeRanges: [],
                timezoneIdentifier: "Etc/UTC"
            )
            repository = MockRepositories(window: invalid).window
        case .grdb:
            let database = try DatabaseFactory.makeInMemoryDatabase()
            try await database.write { db in
                try db.execute(
                    sql: "UPDATE ReminderWindow SET allowedTimeRangesJson = '[]' WHERE id = 1"
                )
            }
            repository = GRDBRepositories(dbQueue: database).window
        }

        do {
            _ = try await repository.fetchGlobal()
            Issue.record("Expected fetchGlobal to reject a corrupt reminder window")
        } catch ReminderWindow.ValidationError.noAllowedTimeRanges {
            // Expected. Both backends must expose the same read failure.
        } catch {
            Issue.record("Expected noAllowedTimeRanges, got \(error)")
        }
    }
}
