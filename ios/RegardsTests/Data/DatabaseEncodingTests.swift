import Foundation
import GRDB
import Testing
@testable import Regards

struct DatabaseEncodingTests {
    @Test("Migration JSON helper rejects invalid UTF-8")
    func migrationJSONHelperRejectsInvalidUTF8() {
        #expect(throws: DataError.invalidJSONEncoding) {
            _ = try JSONEncoder.regardsJSONString(from: Data([0xFF]))
        }
    }

    @Test("Saved nil quiet hours use SQL NULL rather than JSON null")
    func savedNilQuietHoursUseSQLNullNotStringNull() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabase()
        let repository = GRDBRepositories(dbQueue: queue).window

        func storedValue() async throws -> (String?, String) {
            try await queue.read { database in
                guard let row = try Row.fetchOne(
                    database,
                    sql: "SELECT quietHoursJson, typeof(quietHoursJson) AS storageType "
                        + "FROM ReminderWindow WHERE id = 1"
                ) else {
                    throw DataError.notFound
                }
                return (row["quietHoursJson"], row["storageType"])
            }
        }

        let seed = try await repository.fetchGlobal()
        #expect(seed.quietHours != nil)
        let withoutQuietHours = ReminderWindow(
            allowedDays: seed.allowedDays,
            allowedTimeRanges: seed.allowedTimeRanges,
            quietHours: nil,
            timezoneIdentifier: seed.timezoneIdentifier,
            occasionTime: seed.occasionTime,
            digestHorizonDays: seed.digestHorizonDays
        )
        try await repository.saveGlobal(withoutQuietHours)

        let saved = try await storedValue()
        #expect(saved.0 == nil)
        #expect(saved.1 == "null")
        #expect(try await repository.fetchGlobal() == withoutQuietHours)
    }

    @Test("v1 upgrade preserves an invalid contact override for visible read failure")
    func v1UpgradePreservesInvalidContactOverrideForVisibleReadFailure() async throws {
        let queue = try DatabaseQueue()
        let migrator = RegardsSchema.migrator()
        try migrator.migrate(queue, upTo: "v1")

        let contactID = try #require(
            UUID(uuidString: "60000000-0000-0000-0000-000000000006")
        )
        let invalidOverride = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [
                TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17)),
            ],
            timezoneIdentifier: "Not/A_Timezone"
        )
        let overrideData = try JSONEncoder().encode(invalidOverride)
        let overrideJSON = try #require(String(data: overrideData, encoding: .utf8))

        try await queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO Contact
                        (id, systemContactRef, displayName, tracked, preferredChannel,
                         reminderWindowOverride, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    contactID.uuidString,
                    "legacy-invalid-window-contact",
                    "Legacy Invalid Window Contact",
                    true,
                    Channel.phoneCall.rawValue,
                    overrideJSON,
                    1_700_000_000,
                ]
            )
        }

        try migrator.migrate(queue)

        do {
            _ = try await GRDBRepositories(dbQueue: queue).contacts.fetch(id: contactID)
            Issue.record("Expected the invalid legacy override to remain visibly unreadable")
        } catch ReminderWindow.ValidationError.invalidTimezoneIdentifier("Not/A_Timezone") {
            // The migration must not silently replace user timing with the global window.
        } catch {
            Issue.record("Expected invalidTimezoneIdentifier, got \(error)")
        }
    }
}
