import Foundation
import GRDB

/// GRDB schema + migrations for the Regards local DB (ARCHITECTURE.md §7).
/// Every table + index listed in §7 lands in the `v1` migration.
public enum RegardsSchema {

    public static func migrator() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try createV1Tables(db)
            try createV1Indexes(db)
            try seedSingletonRows(db)
        }
        m.registerMigration("v2") { db in
            try migrateToV2(db)
        }
        return m
    }

    // MARK: - v2 columns

    private static func migrateToV2(_ db: Database) throws {
        try db.alter(table: "Contact") { t in
            t.add(column: "phonesJson", .text).notNull().defaults(to: "[]")
            t.add(column: "emailsJson", .text).notNull().defaults(to: "[]")
        }
        try db.alter(table: "ReminderWindow") { t in
            t.add(column: "occasionTime", .text).notNull().defaults(to: "09:00")
            t.add(column: "digestHorizonDays", .integer).notNull().defaults(to: 14)
        }
        try db.alter(table: "UserProfile") { t in
            t.add(column: "trialStartedAt", .integer)
        }

        // v1's seed encoded an Optional at the top level. A nil quiet-hours
        // value therefore became the JSON text `null` instead of SQL NULL
        // (R39). Normalize any such row while v2 is touching the singleton.
        try db.execute(sql: """
            UPDATE ReminderWindow
            SET quietHoursJson = NULL
            WHERE quietHoursJson = 'null'
            """)
    }

    // MARK: - v1 tables

    private static func createV1Tables(_ db: Database) throws {
        try db.create(table: "ContactGroup") { t in
            t.column("id", .text).primaryKey()
            t.column("displayName", .text).notNull()
            t.column("primaryContactId", .text).notNull()
            t.column("createdAt", .integer).notNull()
            t.column("createdBy", .text).notNull()
        }

        try db.create(table: "Contact") { t in
            t.column("id", .text).primaryKey()
            t.column("systemContactRef", .text).notNull().unique()
            t.column("displayName", .text).notNull()
            t.column("photoRef", .text)
            t.column("tracked", .boolean).notNull().defaults(to: false)
            t.column("cadenceDays", .integer)
            t.column("priorityTier", .integer).notNull().defaults(to: 2)
            t.column("preferredChannel", .text).notNull()
            t.column("preferredChannelValue", .text).notNull().defaults(to: "")
            t.column("reminderWindowOverride", .text)       // JSON blob
            t.column("lastInteractedAt", .integer)           // epoch seconds
            t.column("notes", .text).notNull().defaults(to: "")
            t.column("contactGroupId", .text)
                .references("ContactGroup", onDelete: .setNull)
            t.column("createdAt", .integer).notNull()
            t.column("archivedAt", .integer)
        }

        try db.create(table: "ReminderWindow") { t in
            t.column("id", .integer).primaryKey()
            t.check(sql: "id = 1")
            t.column("allowedDaysMask", .integer).notNull()
            t.column("allowedTimeRangesJson", .text).notNull()
            t.column("quietHoursJson", .text)
            t.column("timezone", .text).notNull()
        }

        try db.create(table: "ScheduledReminder") { t in
            t.column("id", .text).primaryKey()
            t.column("contactId", .text).notNull()
                .references("Contact", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("occasionDate", .text)
            t.column("occasionLabel", .text)
            t.column("scheduledFor", .integer).notNull()
            t.column("osNotificationId", .text).notNull()
            t.column("state", .text).notNull()
        }

        try db.create(table: "InteractionLog") { t in
            t.column("id", .text).primaryKey()
            t.column("contactId", .text).notNull()
                .references("Contact", onDelete: .cascade)
            t.column("occurredAt", .integer).notNull()
            t.column("source", .text).notNull()
            t.column("channel", .text)
        }

        try db.create(table: "UserProfile") { t in
            t.column("id", .integer).primaryKey()
            t.check(sql: "id = 1")
            t.column("onboardingCompletedAt", .integer)
            t.column("entitlementTier", .text).notNull()
            t.column("entitlementRefreshedAt", .integer).notNull()
        }
    }

    // MARK: - v1 indexes

    private static func createV1Indexes(_ db: Database) throws {
        try db.create(indexOn: "Contact", columns: ["tracked", "archivedAt"])
        try db.create(indexOn: "Contact", columns: ["contactGroupId"])
        try db.create(indexOn: "ScheduledReminder", columns: ["state", "scheduledFor"])
    }

    // MARK: - Singleton rows

    private static func seedSingletonRows(_ db: Database) throws {
        // v1 encoded nil quiet hours as JSON `null`; the append-only v2
        // migration below normalizes that legacy seed to SQL NULL (R39).
        let window = ReminderWindow.defaultV1(timezone: TimeZone.current)
        try db.execute(literal: """
            INSERT INTO ReminderWindow (id, allowedDaysMask, allowedTimeRangesJson, quietHoursJson, timezone)
            VALUES (1, \(window.allowedDays.rawValue),
                    \(try JSONEncoder().jsonStringEncoded(window.allowedTimeRanges)),
                    \(try JSONEncoder().jsonStringEncoded(window.quietHours)),
                    \(window.timezoneIdentifier))
            """)

        // Default UserProfile.
        let profile = UserProfile()
        let tier = profile.entitlementTier.rawValue
        let refreshedAt = Int(profile.entitlementRefreshedAt.timeIntervalSince1970)
        try db.execute(literal: """
            INSERT INTO UserProfile
                (id, onboardingCompletedAt, entitlementTier, entitlementRefreshedAt)
            VALUES (1, NULL, \(tier), \(refreshedAt))
            """)
    }
}

// MARK: - JSON helper

extension JSONEncoder {
    fileprivate func jsonStringEncoded<T: Encodable>(_ value: T) throws -> String {
        try Self.regardsJSONString(from: encode(value))
    }

    static func regardsJSONString(from data: Data) throws -> String {
        guard let json = String(data: data, encoding: .utf8) else {
            throw DataError.invalidJSONEncoding
        }
        return json
    }
}
