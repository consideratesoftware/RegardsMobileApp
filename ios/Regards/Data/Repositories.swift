import Foundation
import GRDB

// Repository protocols — the "seam" the UI layer depends on. GRDB
// implementations live immediately below; PR3 will inject a `MockRepositories`
// instance that satisfies the same protocols so the UI shell can render
// against seeded data.

public protocol ContactRepository: Sendable {
    /// Fail-closed read: throws if a single stored row can't be decoded.
    /// `MergeDuplicatesViewModel`'s full-handle-set duplicate detection uses
    /// this and needs it to stay all-or-nothing. `ContactsImporter` and
    /// `ContactsReconciler` do **not** use this for their existing-ref
    /// check — they read `fetchAllWithDiagnostics()` instead so a corrupt
    /// row doesn't abort an otherwise-healthy import/reconcile pass; a
    /// corrupted row's `systemContactRef` is folded into their
    /// already-resolved set from the diagnostics list so it's never
    /// mistaken for new. Net effect: a first-launch import against a
    /// database that already has one corrupt row now proceeds and imports
    /// everything else instead of failing outright. Callers that need to
    /// keep working around one bad row use `fetchAllWithDiagnostics()`
    /// directly (R50).
    func fetchAll() async throws -> [Contact]
    func fetchTracked() async throws -> [Contact]
    func fetch(id: UUID) async throws -> Contact?
    /// Returns every contact whose `contactGroupId` matches `groupId`,
    /// **including archived members**. ContactGroup is a virtual merge target
    /// (ARCHITECTURE.md §7); archival is a contact-level concept and does not
    /// silently change group membership. Callers that want active-only
    /// members filter on `isActive` themselves.
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact]
    func upsert(_ contact: Contact) async throws
    func archive(id: UUID, at: Date) async throws
    /// Field-scoped write for `ContactsReconciler` refresh passes (should-fix,
    /// TF-03 round 7): updates exactly the system-owned columns a reconcile
    /// pass can touch — `displayName`, phone/email arrays, `preferredChannelValue`
    /// when re-derived, and `archivedAt` (covers both the archive sweep and
    /// un-archival) — and leaves every other column untouched. `upsert(_:)`
    /// does a whole-row overwrite from whatever `Contact` value the caller
    /// hands it; `ContactsReconciler` builds that value from a snapshot read
    /// at the *start* of a pass, so using `upsert` for a refresh could
    /// silently revert a concurrent user write (e.g. a "mark caught up"
    /// `lastInteractedAt` update) that landed on the same row between the
    /// snapshot and the write. This method can't do that, because it never
    /// reads the row it's writing — it only ever sets these five columns.
    /// A no-op if `id` doesn't match a stored row (same as `archive(id:at:)`).
    func updateReconciledFields(id: UUID, fields: ReconciledContactFields) async throws
    /// Corruption-aware read (R50, `AllContactsViewModel`): every row that
    /// decodes, plus a diagnostic for each row that doesn't. Never mutates,
    /// deletes, or silently skips the corrupt row — it stays exactly as
    /// stored so a later fix (or export) can still reach it. Only a read
    /// failure that isn't about one row's content (e.g. the database itself
    /// is unreachable) throws.
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport
}

/// One stored `Contact` row GRDB fetched but could not decode into the
/// domain type — malformed JSON in `phonesJson`/`emailsJson`, an invalid
/// stored enum, etc. `rawId` is the raw `id` column value, not necessarily a
/// valid UUID, since corruption can affect any column including the
/// identifier itself.
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

/// The exact column set `ContactRepository.updateReconciledFields` may
/// touch — see that method's doc comment. A struct rather than five loose
/// parameters both keeps the call site under the lint parameter-count limit
/// and makes "these five, no others" a type a caller can't accidentally
/// widen.
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
    /// writes always round-trip through `ContactRecord` first): everything
    /// `fetchAll()` returns is healthy and nothing is corrupted. `GRDBContact
    /// Repository` overrides this with a real per-row decode.
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport {
        ContactFetchReport(contacts: try await fetchAll(), corrupted: [])
    }

    /// Fallback for backends that don't need (or, for a plain in-memory
    /// dictionary fake, can't meaningfully benefit from) a true field-scoped
    /// write: fetch, apply the five fields, upsert. `GRDBContactRepository`
    /// and `MockContactRepository` — the two backends the reconciler
    /// actually runs against in production and in previews/UI tests —
    /// override this with a write that never reads the row first.
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
/// code owns one instance of this; tests swap in `MockRepositories` at the
/// protocol seam.
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

    /// Stamps `archivedAt` as integer epoch seconds. Sub-second precision on
    /// the input `Date` is dropped silently; the schema stores every Date
    /// column the same way (see `Records.swift` and ARCHITECTURE.md §7).
    func archive(id: UUID, at: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE Contact SET archivedAt = ? WHERE id = ?",
                arguments: [Int(at.timeIntervalSince1970), id.uuidString])
        }
    }

    /// Real field-scoped `UPDATE` — see the protocol doc comment. Never
    /// reads the row first, so it can't clobber a concurrent write to any
    /// column outside the five listed here.
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

    /// `Records.swift`'s `encodeJSON` helper is file-private there; this is
    /// the same encoding (`JSONEncoder` + UTF-8 string), duplicated rather
    /// than widening that helper's visibility for one extra call site.
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
