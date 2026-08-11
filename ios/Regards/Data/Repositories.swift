import Foundation
import GRDB

// Repository protocols — the "seam" the UI layer depends on. GRDB
// implementations live immediately below; `MockRepositories` satisfies the
// same protocols so the UI shell can render against seeded data.

public protocol ContactRepository: Sendable {
    /// Fail-closed read: throws if a single stored row can't be decoded.
    /// `MergeDuplicatesViewModel`'s full-handle-set duplicate detection uses
    /// this and needs it all-or-nothing. `ContactsImporter` and
    /// `ContactsReconciler` don't use this for their existing-ref check —
    /// they read `fetchAllWithDiagnostics()` instead, folding a corrupted
    /// row's `systemContactRef` into their resolved set so it's never
    /// mistaken for new and one bad row can't abort an otherwise-healthy
    /// pass. Callers that need to keep working around one bad row use
    /// `fetchAllWithDiagnostics()` directly (R50).
    func fetchAll() async throws -> [Contact]
    func fetchTracked() async throws -> [Contact]
    func fetch(id: UUID) async throws -> Contact?
    /// Returns every contact whose `contactGroupId` matches `groupId`,
    /// **including archived members** (archival is contact-level, not a
    /// group-membership change — ARCHITECTURE.md §7). Callers that want
    /// active-only members filter on `isActive` themselves.
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact]
    func upsert(_ contact: Contact) async throws
    func archive(id: UUID, at: Date) async throws
    /// Live view of `fetchTracked()`'s result set: yields the current tracked,
    /// active contacts again after any write that could change the set —
    /// never on subscribe (ARCHITECTURE.md §14 PR22 — Overdue/Upcoming's
    /// cadence rows stay current after an action on a different screen).
    /// Scoped to `Contact` reads only: the `ScheduledReminder ⋈ Contact` join
    /// Upcoming's occasion rows need stays on-the-fly until TF-07 (R10).
    /// Never replays the current value on subscribe — the subscriber's own
    /// `fetchTracked()` read is the sole source of initial state; an eager
    /// replay could land after a caller's optimistic update and stomp it
    /// back to stale. Defaults to a stream that finishes immediately, so
    /// read-only fakes don't need an implementation; `GRDBContactRepository`
    /// and `MockContactRepository` override it with a real live stream.
    func observeTracked() async -> AsyncStream<[Contact]>
    /// Field-scoped write for `ContactsReconciler` refresh passes (should-fix,
    /// TF-03 round 7): updates exactly the system-owned columns a reconcile
    /// pass can touch — `displayName`, phone/email arrays,
    /// `preferredChannelValue` when re-derived, and `archivedAt` — and leaves
    /// every other column untouched. `upsert(_:)` does a whole-row overwrite
    /// from a `Contact` value; `ContactsReconciler` builds that from a
    /// snapshot taken at the *start* of a pass, so using `upsert` for a
    /// refresh could silently revert a concurrent user write (e.g. a "mark
    /// caught up" `lastInteractedAt` update) landing on the same row between
    /// snapshot and write. This method can't do that — it never reads the
    /// row it's writing. A no-op if `id` doesn't match a stored row.
    func updateReconciledFields(id: UUID, fields: ReconciledContactFields) async throws
    /// Corruption-aware read (R50, `AllContactsViewModel`): every row that
    /// decodes, plus a diagnostic for each row that doesn't. Never mutates,
    /// deletes, or silently skips the corrupt row — it stays exactly as
    /// stored so a later fix (or export) can still reach it.
    ///
    /// Narrower than "any row-content problem": covers
    /// `ContactRecord.toDomain()` decode failures (malformed
    /// `phonesJson`/`emailsJson`, an invalid stored enum/UUID) — the shapes
    /// R50 was written against. A raw SQLite column-type mismatch at the
    /// `FetchableRecord` level still throws through this method uncaught,
    /// same as any other read failure — a schema-level integrity problem
    /// this pass doesn't try to paper over,
    /// not a single row's content (ARCHITECTURE.md §19 R50 scope note).
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport
}

extension ContactRepository {
    public func observeTracked() async -> AsyncStream<[Contact]> {
        AsyncStream { $0.finish() }
    }
}

/// One stored `Contact` row GRDB fetched but could not decode — malformed
/// JSON in `phonesJson`/`emailsJson`, an invalid stored enum, etc. `rawId` is
/// the raw `id` column value, not necessarily a valid UUID, since corruption
/// can affect any column including the identifier itself.
public struct ContactCorruptionDiagnostic: Sendable, Equatable {
    public let rawId: String
    public let systemContactRef: String
    public let reason: String

    public init(rawId: String, systemContactRef: String, reason: String) {
        self.rawId = rawId
        self.systemContactRef = systemContactRef
        self.reason = reason
    }
}

/// Result of a corruption-aware `Contact` read: healthy rows plus a
/// diagnostic for every row that failed to decode.
public struct ContactFetchReport: Sendable, Equatable {
    public let contacts: [Contact]
    public let corrupted: [ContactCorruptionDiagnostic]

    public init(contacts: [Contact], corrupted: [ContactCorruptionDiagnostic]) {
        self.contacts = contacts
        self.corrupted = corrupted
    }
}

/// The exact column set `ContactRepository.updateReconciledFields` may touch
/// — see that method's doc comment. A struct rather than five loose
/// parameters keeps the call site under the lint parameter-count limit and
/// makes "these five, no others" a type a caller can't accidentally widen.
public struct ReconciledContactFields: Sendable, Equatable {
    public let displayName: String
    public let phoneNumbers: [String]
    public let emailAddresses: [String]
    public let preferredChannelValue: String
    public let archivedAt: Date?

    public init(
        displayName: String,
        phoneNumbers: [String],
        emailAddresses: [String],
        preferredChannelValue: String,
        archivedAt: Date?
    ) {
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.preferredChannelValue = preferredChannelValue
        self.archivedAt = archivedAt
    }
}

public extension ContactRepository {
    /// Default corruption-aware read for backends that never produce an
    /// undecodable row (in-memory fakes and `MockContactRepository`, whose
    /// writes round-trip through `ContactRecord` first): everything
    /// `fetchAll()` returns is healthy. `GRDBContactRepository` overrides
    /// this with a real per-row decode.
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport {
        ContactFetchReport(contacts: try await fetchAll(), corrupted: [])
    }

    /// Fallback for backends that don't need (or, for a plain in-memory
    /// dictionary fake, can't benefit from) a true field-scoped write: fetch,
    /// apply the five fields, upsert. `GRDBContactRepository` and
    /// `MockContactRepository` override this with a write that never reads
    /// the row first.
    func updateReconciledFields(id: UUID, fields: ReconciledContactFields) async throws {
        guard var contact = try await fetch(id: id) else { return }
        contact.displayName = fields.displayName
        contact.phoneNumbers = fields.phoneNumbers
        contact.emailAddresses = fields.emailAddresses
        contact.preferredChannelValue = fields.preferredChannelValue
        contact.archivedAt = fields.archivedAt
        try await upsert(contact)
    }
}

public protocol ContactGroupRepository: Sendable {
    func fetchAll() async throws -> [ContactGroup]
    func fetch(id: UUID) async throws -> ContactGroup?
    func upsert(_ group: ContactGroup) async throws
    /// Deletes the virtual group and clears `contactGroupId` on every member.
    func delete(id: UUID) async throws
}

public protocol ReminderRepository: Sendable {
    /// Pending reminders ordered by `scheduledFor`, then `id`, ascending.
    func fetchAllPending() async throws -> [ScheduledReminder]
    /// The contact's pending reminders ordered by `scheduledFor`, then `id`, ascending.
    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder]
    func upsert(_ reminder: ScheduledReminder) async throws
    func updateState(id: UUID, state: ReminderState) async throws
    func delete(id: UUID) async throws
}

public protocol InteractionRepository: Sendable {
    /// The contact's logs ordered by `occurredAt` descending, then `id` ascending.
    func fetchRecent(forContact contactId: UUID, limit: Int) async throws -> [InteractionLog]
    func append(_ log: InteractionLog) async throws
}

public protocol ReminderWindowRepository: Sendable {
    func fetchGlobal() async throws -> ReminderWindow
    /// Validates the window before replacing the persisted singleton.
    func saveGlobal(_ window: ReminderWindow) async throws
}

public protocol UserProfileRepository: Sendable {
    func fetch() async throws -> UserProfile
    func save(_ profile: UserProfile) async throws
}

// MARK: - GRDB implementations

/// Bag-of-repositories backed by a single GRDB `DatabaseQueue`. Production
/// owns one instance; tests swap in `MockRepositories` at the protocol seam.
public struct GRDBRepositories: Sendable {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public var contacts: any ContactRepository { GRDBContactRepository(dbQueue: dbQueue) }
    public var groups: any ContactGroupRepository { GRDBContactGroupRepository(dbQueue: dbQueue) }
    public var reminders: any ReminderRepository { GRDBReminderRepository(dbQueue: dbQueue) }
    public var interactions: any InteractionRepository { GRDBInteractionRepository(dbQueue: dbQueue) }
    public var window: any ReminderWindowRepository { GRDBReminderWindowRepository(dbQueue: dbQueue) }
    public var profile: any UserProfileRepository { GRDBUserProfileRepository(dbQueue: dbQueue) }
}

struct GRDBContactRepository: ContactRepository {
    let dbQueue: DatabaseQueue

    func fetchAll() async throws -> [Contact] {
        try await dbQueue.read { db in
            try ContactRecord.fetchAll(db).map { try $0.toDomain() }
        }
    }

    func fetchTracked() async throws -> [Contact] {
        try await dbQueue.read { db in
            try ContactRecord
                .filter(Column("tracked") == true && Column("archivedAt") == nil)
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func fetch(id: UUID) async throws -> Contact? {
        try await dbQueue.read { db in
            try ContactRecord.fetchOne(db, key: id.uuidString).map { try $0.toDomain() }
        }
    }

    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        try await dbQueue.read { db in
            try ContactRecord
                .filter(Column("contactGroupId") == groupId.uuidString)
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func upsert(_ contact: Contact) async throws {
        let record = try ContactRecord(from: contact)
        try await dbQueue.write { db in
            try record.save(db)
        }
    }

    /// Stamps `archivedAt` as integer epoch seconds, dropping sub-second
    /// precision silently — every Date column stores this way (`Records.swift`, ARCHITECTURE.md §7).
    func archive(id: UUID, at: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE Contact SET archivedAt = ? WHERE id = ?",
                arguments: [Int(at.timeIntervalSince1970), id.uuidString])
        }
    }

    func observeTracked() async -> AsyncStream<[Contact]> {
        let observation = ValueObservation.tracking { db in
            try ContactRecord
                .filter(Column("tracked") == true && Column("archivedAt") == nil)
                .fetchAll(db)
        }
        return AsyncStream { continuation in
            // `ValueObservation.start` always fires once immediately with the
            // current value — that first call is the replay the protocol doc
            // says never to send; only a later change reaches `continuation`.
            // An earlier version tried `observation.values(in: dbQueue)
            // .dropFirst()` to avoid this hand-rolled flag; it hung
            // indefinitely in the contract-test suite (both backends) for
            // reasons not further investigated. Reverted to this proven form.
            var isInitialValue = true
            let cancellable = observation.start(
                in: dbQueue,
                onError: { _ in
                    // Ends the live stream; the screen keeps its last-known
                    // rows rather than crash, matching every other read
                    // path's fail-visible-not-fail-crash posture.
                    continuation.finish()
                },
                onChange: { records in
                    if isInitialValue {
                        isInitialValue = false
                        return
                    }
                    let contacts = (try? records.map { try $0.toDomain() }) ?? []
                    continuation.yield(contacts)
                }
            )
            // `AnyDatabaseCancellable` predates GRDB's own Sendable audit.
            // Boxing it — rather than a file-wide `@preconcurrency import
            // GRDB` that would downgrade every Sendable diagnostic in this
            // file — scopes `@unchecked` to exactly the one call this makes:
            // `cancel()`. That call isn't thread-safe by itself (GRDB 6.29's
            // implementation is an unguarded `_cancel?(); _cancel = nil`);
            // safety here comes from cardinality, not synchronization —
            // `AsyncStream.onTermination` fires at most once, so exactly one
            // caller ever reaches `cancel()` through it. Invariant this
            // depends on: `box.cancellable.cancel()` must never gain a
            // second call site outside `onTermination` below.
            let box = CancellableBox(cancellable)
            continuation.onTermination = { _ in box.cancellable.cancel() }
        }
    }

    /// Real field-scoped `UPDATE` — see the protocol doc comment. Never
    /// reads the row first, so it can't clobber a concurrent write outside
    /// the five columns listed here.
    func updateReconciledFields(id: UUID, fields: ReconciledContactFields) async throws {
        let phonesJson = try Self.encodeJSONArray(fields.phoneNumbers)
        let emailsJson = try Self.encodeJSONArray(fields.emailAddresses)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE Contact
                    SET displayName = ?, phonesJson = ?, emailsJson = ?, \
                        preferredChannelValue = ?, archivedAt = ?
                    WHERE id = ?
                    """,
                arguments: [
                    fields.displayName, phonesJson, emailsJson, fields.preferredChannelValue,
                    fields.archivedAt.map { Int($0.timeIntervalSince1970) }, id.uuidString,
                ])
        }
    }

    /// Duplicates `Records.swift`'s file-private `encodeJSON` (same
    /// `JSONEncoder` + UTF-8 encoding) rather than widening its visibility
    /// for one extra call site.
    private static func encodeJSONArray(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw DataError.invalidJSONEncoding
        }
        return json
    }

    func fetchAllWithDiagnostics() async throws -> ContactFetchReport {
        try await dbQueue.read { db in
            let records = try ContactRecord.fetchAll(db)
            var healthy: [Contact] = []
            var corrupted: [ContactCorruptionDiagnostic] = []
            healthy.reserveCapacity(records.count)
            for record in records {
                do {
                    healthy.append(try record.toDomain())
                } catch {
                    corrupted.append(ContactCorruptionDiagnostic(
                        rawId: record.id,
                        systemContactRef: record.systemContactRef,
                        reason: String(describing: error)
                    ))
                }
            }
            return ContactFetchReport(contacts: healthy, corrupted: corrupted)
        }
    }
}

/// See `GRDBContactRepository.observeTracked()`'s doc comment for why this
/// exists instead of a file-wide `@preconcurrency import GRDB`.
private final class CancellableBox: @unchecked Sendable {
    let cancellable: AnyDatabaseCancellable
    init(_ cancellable: AnyDatabaseCancellable) {
        self.cancellable = cancellable
    }
}

struct GRDBContactGroupRepository: ContactGroupRepository {
    let dbQueue: DatabaseQueue

    func fetchAll() async throws -> [ContactGroup] {
        try await dbQueue.read { db in
            try ContactGroupRecord.fetchAll(db).map { try $0.toDomain() }
        }
    }

    func fetch(id: UUID) async throws -> ContactGroup? {
        try await dbQueue.read { db in
            try ContactGroupRecord.fetchOne(db, key: id.uuidString).map { try $0.toDomain() }
        }
    }

    func upsert(_ group: ContactGroup) async throws {
        let record = ContactGroupRecord(from: group)
        try await dbQueue.write { db in try record.save(db) }
    }

    func delete(id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE Contact SET contactGroupId = NULL WHERE contactGroupId = ?",
                arguments: [id.uuidString])
            _ = try ContactGroupRecord.deleteOne(db, key: id.uuidString)
        }
    }
}

struct GRDBReminderRepository: ReminderRepository {
    let dbQueue: DatabaseQueue

    func fetchAllPending() async throws -> [ScheduledReminder] {
        try await dbQueue.read { db in
            try ScheduledReminderRecord
                .filter(Column("state") == ReminderState.pending.rawValue)
                .order(Column("scheduledFor"), Column("id"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder] {
        try await dbQueue.read { db in
            try ScheduledReminderRecord
                .filter(Column("contactId") == contactId.uuidString
                        && Column("state") == ReminderState.pending.rawValue)
                .order(Column("scheduledFor"), Column("id"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func upsert(_ reminder: ScheduledReminder) async throws {
        let record = ScheduledReminderRecord(from: reminder)
        try await dbQueue.write { db in try record.save(db) }
    }

    func updateState(id: UUID, state: ReminderState) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE ScheduledReminder SET state = ? WHERE id = ?",
                arguments: [state.rawValue, id.uuidString])
        }
    }

    func delete(id: UUID) async throws {
        try await dbQueue.write { db in
            _ = try ScheduledReminderRecord.deleteOne(db, key: id.uuidString)
        }
    }
}

struct GRDBInteractionRepository: InteractionRepository {
    let dbQueue: DatabaseQueue

    func fetchRecent(forContact contactId: UUID, limit: Int) async throws -> [InteractionLog] {
        guard limit > 0 else { return [] }
        return try await dbQueue.read { db in
            try InteractionLogRecord
                .filter(Column("contactId") == contactId.uuidString)
                .order(Column("occurredAt").desc, Column("id"))
                .limit(limit)
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    func append(_ log: InteractionLog) async throws {
        let record = InteractionLogRecord(from: log)
        try await dbQueue.write { db in try record.insert(db) }
    }
}

struct GRDBReminderWindowRepository: ReminderWindowRepository {
    let dbQueue: DatabaseQueue

    func fetchGlobal() async throws -> ReminderWindow {
        try await dbQueue.read { db in
            guard let rec = try ReminderWindowRecord.fetchOne(db, key: 1) else {
                throw DataError.notFound
            }
            return try rec.toDomain()
        }
    }

    func saveGlobal(_ window: ReminderWindow) async throws {
        try window.validate()
        let record = try ReminderWindowRecord(from: window)
        try await dbQueue.write { db in try record.save(db) }
    }
}

struct GRDBUserProfileRepository: UserProfileRepository {
    let dbQueue: DatabaseQueue

    func fetch() async throws -> UserProfile {
        try await dbQueue.read { db in
            guard let rec = try UserProfileRecord.fetchOne(db, key: 1) else {
                throw DataError.notFound
            }
            return rec.toDomain()
        }
    }

    func save(_ profile: UserProfile) async throws {
        let record = UserProfileRecord(from: profile)
        try await dbQueue.write { db in try record.save(db) }
    }
}
