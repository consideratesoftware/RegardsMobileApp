import Foundation
import GRDB

/// Opens the app's GRDB database with the right file-protection class
/// (ARCHITECTURE.md §11: `NSFileProtectionCompleteUntilFirstUserAuthentication`
/// on iOS) and applies all migrations.
public enum DatabaseFactory {

    public enum OpenError: Error, Equatable {
        case applicationSupportDirectoryMissing
    }

    /// Production database — persists under Application Support/Regards.
    public static func makeDatabase(fileName: String = "regards.sqlite")
        throws -> DatabaseQueue
    {
        let fm = FileManager.default
        let root = try fm.url(for: .applicationSupportDirectory,
                              in: .userDomainMask,
                              appropriateFor: nil,
                              create: true)
        return try makeDatabase(
            applicationSupportDirectory: root,
            fileName: fileName,
            fileManager: fm
        )
    }

    /// Shared production-path implementation. The injectable Application
    /// Support root keeps directory creation, file protection, migration, and
    /// reopen behavior covered without writing unit-test databases into the
    /// app's real container.
    static func makeDatabase(
        applicationSupportDirectory root: URL,
        fileName: String,
        fileManager fm: FileManager = .default
    ) throws -> DatabaseQueue {
        let dir = root.appendingPathComponent("Regards", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Apply file protection to the directory — every file created inside
        // inherits the class.
        try fm.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )

        let queue = try DatabaseQueue(path: dir.appendingPathComponent(fileName).path)
        try RegardsSchema.migrator().migrate(queue)
        return queue
    }

    /// In-memory database for unit tests. Schema is applied so repos can
    /// round-trip rows without touching disk.
    public static func makeInMemoryDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try RegardsSchema.migrator().migrate(queue)
        return queue
    }
}

/// Owns the GRDB-facing half of production composition. App-layer callers
/// receive only an `AppEnvironment` of repository protocol existentials; the
/// concrete database queue never crosses into launch or SwiftUI composition.
public enum ProductionRepositoryFactory {
    public static func makeFileBackedEnvironment() throws -> AppEnvironment {
        makeEnvironment(database: try DatabaseFactory.makeDatabase())
    }

    static func makeFileBackedEnvironment(
        applicationSupportDirectory root: URL,
        fileName: String,
        fileManager: FileManager = .default
    ) throws -> AppEnvironment {
        makeEnvironment(
            database: try DatabaseFactory.makeDatabase(
                applicationSupportDirectory: root,
                fileName: fileName,
                fileManager: fileManager
            )
        )
    }

    public static func makeInMemoryEnvironment() throws -> AppEnvironment {
        makeEnvironment(database: try DatabaseFactory.makeInMemoryDatabase())
    }

    public static func makeEnvironment(database: DatabaseQueue) -> AppEnvironment {
        let repositories = GRDBRepositories(dbQueue: database)
        return AppEnvironment(
            contacts: repositories.contacts,
            groups: repositories.groups,
            reminders: repositories.reminders,
            interactions: repositories.interactions,
            window: repositories.window,
            profile: repositories.profile
        )
    }
}
