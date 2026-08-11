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
    /// Field-scoped write for "Caught up" / "Log other channel…"
    /// (`InteractionLogging.record`) — moves exactly `lastInteractedAt`,
    /// same reason as `updateReconciledFields` above: `InteractionLogging`
    /// builds its write from a `Contact` snapshot fetched at the *start* of
    /// the action, so a whole-row `upsert` could silently clobber a
    /// concurrent `ContactsReconciler` field write on the same row in
    /// between (including un-archiving a contact that pass just archived).
    /// Never reads the row it's writing.
    ///
    /// Returns whether `id` matched a stored row — `false`, not a thrown
    /// error, for the ordinary "no row" case (mirrors `updateReconciledFields`'s
    /// silent no-op). `InteractionLogging.record` uses this to distinguish
    /// "the write landed" from "the contact was archived/deleted between the
    /// earlier fetch and this write" — a caller that ignored the return
    /// value and always reported success would announce "Marked X caught
    /// up" for a write that changed nothing (staged review, same class as
    /// blocker 1's occasion-row false confirmation).
    @discardableResult
    func updateLastInteractedAt(id: UUID, at date: Date) async throws -> Bool
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
        // `.bufferingNewest(1)`, not the `.unbounded` default: matches every
        // real conformer's own `observeTracked()` (see
        // `GRDBContactRepository`'s and `MockStore`'s), even though this
        // no-op default finishes immediately and never buffers anything.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { $0.finish() }
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

    /// Fallback mirroring `updateReconciledFields`' own: fetch, move the one
    /// field, upsert. `GRDBContactRepository` and `MockContactRepository`
    /// override this with a write that never reads the row first.
    ///
    /// Excludes an archived contact the same way as "the row doesn't exist"
    /// (staged review round 8): `InteractionLogging.record()`'s `guard
    /// matched else { throw .notFound }` already exists for exactly this
    /// shape of failure — a contact archived between an earlier fetch and
    /// this write — but until now only a *deleted* contact could produce
    /// `matched == false`; an *archived* one silently succeeded here on
    /// both backends while `ContactDetailViewModel.snooze`'s own
    /// `contact.isActive` guard already rejected the identical race for
    /// Snooze. All three actions now agree.
    @discardableResult
    func updateLastInteractedAt(id: UUID, at date: Date) async throws -> Bool {
        guard var contact = try await fetch(id: id), contact.isActive else { return false }
        contact.lastInteractedAt = date
        try await upsert(contact)
        return true
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
    /// Compare-and-set: transitions `id`'s state to `to` only if its
    /// *current* state is still `from`, atomically with that check. Returns
    /// whether the transition actually happened.
    ///
    /// `SchedulingPass.caughtUp` used to pair a separate `fetchPending` read
    /// with `updateState` to learn whether a pending row existed (staged
    /// review round 7); that left a window between the check and the write
    /// where two concurrent callers could both observe the same
    /// pre-transition state and each believe *it* was the one responsible
    /// for the change (staged review round 8). This method closes that
    /// window by making the check part of the same write.
    @discardableResult
    func transitionState(id: UUID, from: ReminderState, to: ReminderState) async throws -> Bool
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
        // `.bufferingNewest(1)`, not the `.unbounded` default: TF-03's
        // `ContactsReconciler` broadcasts once per changed contact through
        // `upsertContact`/`updateReconciledFields`, so an N-contact
        // reconciliation pass would otherwise queue N full `fetchTracked()`
        // reloads per subscribed screen — this collapses that burst to the
        // single latest snapshot, which is all any subscriber ever needs
        // (`observeTracked()`'s own contract is "the current tracked set,"
        // not "every intermediate state along the way").
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // `ValueObservation.start` always fires once immediately with the
            // current value — that first call is the replay the protocol doc
            // says never to send; only a later change reaches `continuation`.
            // An earlier version tried `observation.values(in: dbQueue)
            // .dropFirst()` to avoid this hand-rolled flag; it hung
            // indefinitely in the contract-test suite (both backends) for
            // reasons not further investigated. Reverted to this proven form.
            var isInitialValue = true
            // `onTermination` assigned *before* `start(...)` runs, not
            // after: a synchronous `onError` inside `start(...)` triggers it
            // before a cancellable exists to cancel. See `CancellableBox`
            // for how `set`/`cancel` stay safe regardless of which runs
            // first.
            let box = CancellableBox()
            continuation.onTermination = { _ in box.cancel() }
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
                    // `compactMap`, not `(try? records.map { ... }) ?? []`:
                    // the earlier form let one undecodable row collapse the
                    // *entire* emission to empty — Overdue would render "all
                    // caught up" while every other contact the user still
                    // owes is just as real, silently misreporting their
                    // relationships. `compactMap` drops only the row that
                    // fails, matching `fetchAllWithDiagnostics()`'s R50
                    // per-row tolerance on the ordinary read path — this is
                    // that same tolerance applied to the live-observation
                    // path, which R50 didn't originally reach.
                    continuation.yield(records.compactMap { try? $0.toDomain() })
                }
            )
            box.set(cancellable)
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

    /// Real field-scoped `UPDATE` — see the protocol doc comment. Never
    /// reads the row first, so it can't clobber a concurrent
    /// `ContactsReconciler` write to any other column on the same row.
    /// `db.changesCount` after the `UPDATE` is SQLite's own
    /// `sqlite3_changes()` — the row count the statement actually matched,
    /// not an assumption that a well-formed `id` always exists.
    ///
    /// `AND archivedAt IS NULL` (staged review round 8): without it, this
    /// silently matches — and "succeeds" — a contact the reconciler archived
    /// between an earlier fetch and this write, the identical race
    /// `ContactDetailViewModel.snooze`'s `contact.isActive` guard already
    /// closes for Snooze. See the protocol doc comment for why "archived"
    /// counts as "no match" here.
    @discardableResult
    func updateLastInteractedAt(id: UUID, at date: Date) async throws -> Bool {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE Contact SET lastInteractedAt = ? WHERE id = ? AND archivedAt IS NULL",
                arguments: [Int(date.timeIntervalSince1970), id.uuidString]
            )
            return db.changesCount > 0
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
