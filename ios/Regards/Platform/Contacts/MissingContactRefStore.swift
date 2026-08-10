import Foundation

/// Sidecar persistence for `ContactsReconciler`'s archive-debounce state
/// (`ContactRefHasher.hash(_:)`-keyed refs → the clock time each was first
/// observed missing under `.authorized`). Round 11: keeping this in-memory
/// only (`AppLaunchCoordinator`, rounds 9–10) meant the required two
/// consecutive `.authorized` passes ≥5 minutes apart almost never both
/// landed inside one process lifetime on iOS — the app is rarely kept
/// running foreground for 5+ minutes straight, and every relaunch reset the
/// state to empty — so a genuine contact deletion effectively never
/// archived. Persisting across launches is what actually closes that gap.
///
/// Stored outside the GRDB database on purpose: no DB schema change here —
/// `v3` belongs to TF-07 — and this state is disposable debounce plumbing,
/// not data the app can't function without (losing it just restarts the
/// two-pass clock for whatever was mid-flight, never worse than that).
/// `NSFileProtectionComplete` on the containing directory, stricter than
/// the database's own `NSFileProtectionCompleteUntilFirstUserAuthentication`
/// (ARCHITECTURE.md §11, `DatabaseFactory`) — this file never needs to be
/// read before first unlock the way the database does at early launch, so
/// there's no reason to accept the weaker class for it. Every value is
/// keyed by `ContactRefHasher.hash(_:)`, never a raw `systemContactRef` — no
/// contact identifier lives on disk outside the protected database itself.
///
/// Round 12 correction: this used to live directly in `Application
/// Support/Regards` — the *same* directory `DatabaseFactory.makeDatabase()`
/// protects. Composition order defeated the `.complete` claim above: in
/// production, `AppLaunchCoordinator.production()` constructs this store
/// eagerly (setting `.complete` on that directory), but `makeRuntime`'s
/// closure — which opens the database and re-sets that *same* directory to
/// `.completeUntilFirstUserAuthentication` — only runs later, once `start()`
/// awaits it, silently downgrading the directory (and everything created in
/// it afterward, including this file, which is only ever written by `save()`
/// well after that point) to the weaker class. `applicationSupport()` now
/// gives this store its own `ReconcilerState` subdirectory, nested under
/// `Regards` but never touched by `DatabaseFactory`, so nothing else can
/// silently override the protection class applied here.
public struct MissingContactRefStore: Sendable {
    private let fileURL: URL

    /// Injectable directory, matching `DatabaseFactory`'s pattern: tests
    /// point this at a throwaway temp directory instead of the app's real
    /// container so runs never touch (or collide over) real device state.
    public init(directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Every file created inside `directory` inherits this class —
        // matches `DatabaseFactory.makeDatabase(applicationSupportDirectory:)`'s
        // approach of protecting the directory rather than each file.
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: directory.path
        )
        self.fileURL = directory.appendingPathComponent("contacts-archive-debounce.json")
    }

    private init(unprotectedFileURL: URL) {
        self.fileURL = unprotectedFileURL
    }

    /// Production location: Application Support/Regards/ReconcilerState —
    /// nested under the same `Regards` directory `DatabaseFactory` uses for
    /// the database, but in its own subdirectory, not a sibling file
    /// directly inside `Regards` itself. That nesting is deliberate (round
    /// 12): `DatabaseFactory.makeDatabase()` sets its own protection class
    /// on `Regards` every time it runs, and would silently downgrade this
    /// store's `.complete` claim to the database's weaker
    /// `.completeUntilFirstUserAuthentication` if both protected the same
    /// directory — see the type's own doc comment above for the exact
    /// composition-order bug this was defeating. A subdirectory
    /// `DatabaseFactory` never touches keeps the two independent.
    public static func applicationSupport(fileManager: FileManager = .default) throws -> MissingContactRefStore {
        let root = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return try applicationSupport(root: root, fileManager: fileManager)
    }

    /// Injectable-root variant of `applicationSupport()`, matching
    /// `DatabaseFactory.makeDatabase(applicationSupportDirectory:fileName:fileManager:)`'s
    /// shape — lets a test construct the sidecar and the database against
    /// the *same* injected Application Support root, in the same order
    /// `AppLaunchCoordinator.production()` does, to prove the `.complete`
    /// claim actually survives that composition instead of asserting on
    /// this type in isolation.
    static func applicationSupport(root: URL, fileManager: FileManager = .default) throws -> MissingContactRefStore {
        try MissingContactRefStore(
            directory: root.appendingPathComponent("Regards", isDirectory: true)
                .appendingPathComponent("ReconcilerState", isDirectory: true),
            fileManager: fileManager
        )
    }

    /// A fresh, unique temp-directory-backed store — the default for
    /// `AppLaunchCoordinator.Dependencies.missingContactRefStore` so call
    /// sites that don't care about cross-launch persistence (almost every
    /// existing test) compile and behave unchanged. Practically never
    /// fails (it's a brand-new temp path), but degrades to an unprotected,
    /// still-functional store rather than crash if it somehow does —
    /// `load()`/`save(_:)` already tolerate I/O failure on their own terms.
    public static func ephemeral() -> MissingContactRefStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingContactRefStore-\(UUID().uuidString)", isDirectory: true)
        if let store = try? MissingContactRefStore(directory: directory) {
            return store
        }
        return MissingContactRefStore(unprotectedFileURL: directory.appendingPathComponent(
            "contacts-archive-debounce.json"
        ))
    }

    /// Hashed ref → first-seen-missing timestamp. Empty on any read failure
    /// (no file yet on first-ever launch, corrupt JSON, …) — this state is
    /// a debounce optimization, not data integrity; losing it just means
    /// the next miss restarts the two-pass clock.
    public func load() -> [String: Date] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    public func save(_ missingRefs: [String: Date]) throws {
        let data = try JSONEncoder().encode(missingRefs)
        try data.write(to: fileURL, options: .atomic)
    }
}
