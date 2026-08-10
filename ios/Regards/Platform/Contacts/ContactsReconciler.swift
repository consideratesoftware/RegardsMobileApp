import Foundation

/// Reconciles the persisted `Contact` table against whatever the system
/// Contacts store currently exposes. Runs on every app launch (existing
/// installs), app foreground, and `CNContactStoreDidChange`
/// (ARCHITECTURE.md §7 "Re-import & reconciliation", PR21 / R25 / R35 / R50).
///
/// Reconciliation never deletes a row:
/// - A system contact the store no longer exposes is archived, not deleted,
///   so cadence and interaction history survive for a possible re-add.
/// - A `systemContactRef` that reappears — e.g. the user adds a previously
///   deselected contact back into a `.limited` selection — is un-archived in
///   place. That's distinct from a genuine delete-then-re-add, which the
///   system gives a brand-new identifier, so it lands as a new row instead
///   (the archived original, and its history, stay exactly where they are).
/// - A row this pass can't decode (R50) is left untouched: it is neither
///   matched, refreshed, nor archived, so a corrupt row is never mistaken for
///   a deleted one.
public struct ContactsReconciler: Sendable {
    private let source: any ContactsSource
    private let repo: any ContactRepository
    private let clock: @Sendable () -> Date

    public init(
        source: any ContactsSource,
        repo: any ContactRepository,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.repo = repo
        self.clock = clock
    }

    /// Outcome of one reconciliation pass.
    public struct Result: Sendable, Equatable {
        public let imported: Int
        public let refreshed: Int
        public let archived: Int
        public let unarchived: Int
        public let unchanged: Int
        public let failed: Int

        public init(
            imported: Int = 0,
            refreshed: Int = 0,
            archived: Int = 0,
            unarchived: Int = 0,
            unchanged: Int = 0,
            failed: Int = 0
        ) {
            self.imported = imported
            self.refreshed = refreshed
            self.archived = archived
            self.unarchived = unarchived
            self.unchanged = unchanged
            self.failed = failed
        }
    }

    public enum ReconciliationError: Error, Equatable {
        case notAuthorized(ContactsAuthorizationStatus)
    }

    /// Throws `ReconciliationError.notAuthorized` if the source's current
    /// status isn't `.authorized` or `.limited` — `.limited` reconciles
    /// against exactly the picker-selected subset the system exposes, same
    /// as first-launch import.
    public func reconcile() async throws -> Result {
        let status = await source.currentAuthorization()
        guard status == .authorized || status == .limited else {
            throw ReconciliationError.notAuthorized(status)
        }

        let systemContacts = try await source.fetchAllContacts()
        let visibleRefs = Set(systemContacts.map(\.identifier))
        let report = try await repo.fetchAllWithDiagnostics()
        var byRef: [String: Contact] = [:]
        byRef.reserveCapacity(report.contacts.count)
        for contact in report.contacts { byRef[contact.systemContactRef] = contact }
        // A corrupted row keeps its ref out of both the import-collision
        // check and the archive sweep below — it's neither "new" nor
        // "deleted", just unreadable, and R50 owns showing that separately.
        let corruptedRefs = Set(report.corrupted.map(\.systemContactRef))

        let now = clock()
        var imported = 0, refreshed = 0, unarchived = 0, unchanged = 0, failed = 0

        for systemContact in systemContacts {
            guard !corruptedRefs.contains(systemContact.identifier) else { continue }
            do {
                if let existing = byRef[systemContact.identifier] {
                    let wasArchived = existing.archivedAt != nil
                    let updated = Self.refreshed(existing, with: systemContact, now: now)
                    guard updated != existing else {
                        unchanged += 1
                        continue
                    }
                    try await repo.upsert(updated)
                    if wasArchived {
                        unarchived += 1
                    } else {
                        refreshed += 1
                    }
                } else {
                    try await repo.upsert(ContactsImporter.map(systemContact: systemContact, now: now))
                    imported += 1
                }
            } catch {
                failed += 1
                Self.log.error("""
                    reconciliation failed for \(systemContact.identifier, privacy: .private): \
                    \(error, privacy: .private)
                    """)
            }
        }

        var archived = 0
        for (ref, contact) in byRef where !visibleRefs.contains(ref) && contact.archivedAt == nil {
            do {
                try await repo.archive(id: contact.id, at: now)
                archived += 1
            } catch {
                failed += 1
                Self.log.error(
                    "archive failed for \(contact.id, privacy: .private): \(error, privacy: .private)"
                )
            }
        }

        return Result(
            imported: imported,
            refreshed: refreshed,
            archived: archived,
            unarchived: unarchived,
            unchanged: unchanged,
            failed: failed
        )
    }

    /// Applies the system-derived refresh onto a persisted row: name,
    /// phones, emails, and un-archival if the store exposes the contact
    /// again. `tracked`, `cadenceDays`, `priorityTier`, `preferredChannel`,
    /// `notes`, and group membership are user-owned and never overwritten by
    /// a reconciliation pass. `photoRef` is left alone too: no
    /// `ContactsSource` implementation fetches a photo today, so there is
    /// nothing here to refresh it from yet.
    private static func refreshed(
        _ existing: Contact,
        with systemContact: SystemContact,
        now: Date
    ) -> Contact {
        let mapped = ContactsImporter.map(systemContact: systemContact, now: now)
        var updated = existing
        updated.displayName = mapped.displayName
        updated.phoneNumbers = mapped.phoneNumbers
        updated.emailAddresses = mapped.emailAddresses
        updated.archivedAt = nil
        return updated
    }

    private static let log = RegardsLogger.feature("ContactsReconciler")
}
