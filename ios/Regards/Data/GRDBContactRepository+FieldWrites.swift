import Foundation
import GRDB

// `GRDBContactRepository`'s field-scoped writes (§7), split out of
// `Repositories.swift` to keep that file under the lint length limit. Each
// one is a single `UPDATE` that never reads the row first, so it can't
// revert a concurrent write to any column it doesn't name.
extension GRDBContactRepository {
    /// Real field-scoped `UPDATE` — see the protocol doc comment. Never
    /// reads the row first, so it can't clobber a concurrent write outside
    /// the five columns listed here.
    func updateReconciledFields(id: UUID, fields: ReconciledContactFields) async throws {
        let phonesJson = try encodeJSON(fields.phoneNumbers)
        let emailsJson = try encodeJSON(fields.emailAddresses)
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

    /// Real field-scoped `UPDATE`, same shape as `updateLastInteractedAt`
    /// above: one `UPDATE` with no fetch, matches only an active contact, and
    /// reports the match from `db.changesCount`. A `nil` window binds a Swift
    /// `nil`, which GRDB writes as SQL NULL (R39).
    @discardableResult
    func updateReminderWindowOverride(id: UUID, window: ReminderWindow?) async throws -> Bool {
        try window?.validate()
        let json = try window.map { try encodeJSON($0) }
        return try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE Contact SET reminderWindowOverride = ? WHERE id = ? AND archivedAt IS NULL",
                arguments: [json, id.uuidString]
            )
            return db.changesCount > 0
        }
    }

    /// Real field-scoped `UPDATE`, same shape as `updateLastInteractedAt`
    /// above: validates first, sets exactly `tracked` and `cadenceDays`,
    /// matches only an active contact, and reports the match from
    /// `db.changesCount`. A `nil` cadence binds SQL NULL and `tracked` false.
    @discardableResult
    func updateTracking(id: UUID, cadenceDays: Int?) async throws -> Bool {
        try ContactTrackingError.validate(cadenceDays)
        return try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE Contact SET tracked = ?, cadenceDays = ? WHERE id = ? AND archivedAt IS NULL",
                arguments: [cadenceDays != nil, cadenceDays, id.uuidString]
            )
            return db.changesCount > 0
        }
    }
}
