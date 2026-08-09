import GRDB
import Testing
@testable import Regards

extension SingletonRepositoryContractTests {
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
