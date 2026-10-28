import Foundation
import GRDB
@testable import Regards

/// A real GRDB store whose override column holds text the repositories cannot
/// write, such as a blob stored by an older version. The raw SQL is confined
/// to this helper, so the tests that use it read the result through the
/// repository protocols only.
enum RawOverrideStore {

    /// A fresh in-memory store with `global` as the global window and `contact`
    /// upserted, then `rawOverrideJSON` written verbatim to that contact's
    /// override column.
    static func makeEnvironment(
        global: ReminderWindow, contact: Contact, rawOverrideJSON: String
    ) async throws -> AppEnvironment {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let environment = ProductionRepositoryFactory.makeEnvironment(database: database)
        try await environment.window.saveGlobal(global)
        try await environment.contacts.upsert(contact)
        try await database.write { db in
            try db.execute(
                sql: "UPDATE Contact SET reminderWindowOverride = ? WHERE id = ?",
                arguments: [rawOverrideJSON, contact.id.uuidString]
            )
        }
        return environment
    }
}
