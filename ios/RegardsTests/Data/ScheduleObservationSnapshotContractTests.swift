import Foundation
import GRDB
import Testing
@testable import Regards

/// What an `observeSchedule()` snapshot holds and when it re-emits (R10):
/// ordering, field-scoped contact writes, re-tracking, and rows or reads
/// that fail. Split from `ScheduleObservationContractTests` at the file
/// length limit; shares the same `RepositoryContractBackend` /
/// `contractContact` / `contractUUID` helpers.
@Suite(.timeLimit(.minutes(1)))
struct ScheduleObservationSnapshotContractTests {

    // MARK: - Re-emission

    /// The mock reaches the schedule stream from each field-scoped contact
    /// write through its own `broadcastScheduleChange()` call. GRDB sees them
    /// all as writes to the Contact table. Each case changes one value the
    /// snapshot carries, so a mock that forgets a call never emits it.
    @Test(
        "observeSchedule shows the new value after a field-scoped contact write",
        arguments: RepositoryContractBackend.allCases, ContactFieldWrite.allCases
    )
    func observeScheduleEmitsAfterContactFieldWrite(
        backend: RepositoryContractBackend, write: ContactFieldWrite
    ) async throws {
        let repositories = try backend.makeRepositories()
        let contactID = try contractUUID(701)
        let groupID = try contractUUID(702)
        let reminder = ScheduledReminder(
            id: try contractUUID(703),
            contactId: contactID,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_100),
            osNotificationId: "schedule-fields"
        )
        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "schedule-fields", tracked: true))
        try await repositories.groups.upsert(
            ContactGroup(id: groupID, displayName: "Schedule group", primaryContactId: contactID))
        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "schedule-fields", tracked: true, groupID: groupID))
        try await repositories.reminders.upsert(reminder)

        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.contacts.first { $0.id == contactID }?.contactGroupId == groupID)

        let newOverride = ReminderWindow(
            allowedDays: .weekends,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 12), end: TimeOfDay(hour: 13))],
            timezoneIdentifier: "Etc/UTC"
        )
        let newInteraction = Date(timeIntervalSince1970: 1_800_000_500)
        switch write {
        case .lastInteracted:
            try await repositories.contacts.updateLastInteractedAt(id: contactID, at: newInteraction)
        case .windowOverride:
            try await repositories.contacts.updateReminderWindowOverride(id: contactID, window: newOverride)
        case .reconciledFields:
            try await repositories.contacts.updateReconciledFields(
                id: contactID,
                fields: ReconciledContactFields(
                    displayName: "Reconciled schedule name",
                    phoneNumbers: [],
                    emailAddresses: [],
                    preferredChannelValue: "",
                    archivedAt: nil
                )
            )
        case .deleteGroup:
            try await repositories.groups.delete(id: groupID)
        }

        let afterWrite = try #require(await iterator.next())
        let contact = try #require(afterWrite.contacts.first { $0.id == contactID })
        switch write {
        case .lastInteracted:
            #expect(contact.lastInteractedAt == newInteraction)
        case .windowOverride:
            #expect(contact.reminderWindowOverride == newOverride)
        case .reconciledFields:
            #expect(contact.displayName == "Reconciled schedule name")
        case .deleteGroup:
            #expect(contact.contactGroupId == nil)
        }
    }

    @Test(
        "observeSchedule brings a contact's pending row back when the contact is tracked again",
        arguments: RepositoryContractBackend.allCases
    )
    func observeScheduleRetrackedContactRowsReturn(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contactID = try contractUUID(711)
        let reminder = ScheduledReminder(
            id: try contractUUID(712),
            contactId: contactID,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_100),
            osNotificationId: "schedule-retrack"
        )
        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "schedule-retrack", tracked: true))
        try await repositories.reminders.upsert(reminder)
        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()
        _ = try #require(await iterator.next())

        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "schedule-retrack", tracked: false))
        let whileUntracked = try #require(await iterator.next())
        #expect(!whileUntracked.reminders.map(\.id).contains(reminder.id))

        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "schedule-retrack", tracked: true))
        let afterRetrack = try #require(await iterator.next())
        #expect(afterRetrack.contacts.map(\.id).contains(contactID))
        #expect(afterRetrack.reminders.map(\.id).contains(reminder.id))
    }

    // MARK: - Ordering

    @Test(
        "observeSchedule orders contacts by id and reminders by scheduledFor, then id",
        arguments: RepositoryContractBackend.allCases
    )
    func observeScheduleOrdersContactsByIdAndRemindersByScheduledForThenId(
        backend: RepositoryContractBackend
    ) async throws {
        let repositories = try backend.makeRepositories()
        let first = try contractUUID(721)
        let second = try contractUUID(722)
        let third = try contractUUID(723)
        // Contacts go in out of id order.
        for (id, suffix) in [(third, "order-3"), (first, "order-1"), (second, "order-2")] {
            try await repositories.contacts.upsert(contractContact(id: id, suffix: suffix, tracked: true))
        }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func reminder(_ suffix: Int, contact: UUID, offset: TimeInterval) throws -> ScheduledReminder {
            ScheduledReminder(
                id: try contractUUID(suffix),
                contactId: contact,
                kind: .cadence,
                scheduledFor: base.addingTimeInterval(offset),
                osNotificationId: "order-\(suffix)"
            )
        }
        let late = try reminder(731, contact: first, offset: 10)
        let tiedLowID = try reminder(732, contact: second, offset: 0)
        let tiedHighID = try reminder(733, contact: third, offset: 0)
        // The tied pair goes in reverse id order, after the later row.
        for row in [late, tiedHighID, tiedLowID] {
            try await repositories.reminders.upsert(row)
        }

        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())

        let mine: Set<UUID> = [first, second, third]
        #expect(snapshot.contacts.map(\.id).filter(mine.contains) == [first, second, third])
        let mineRows: Set<UUID> = [late.id, tiedLowID.id, tiedHighID.id]
        #expect(snapshot.reminders.map(\.id).filter(mineRows.contains)
                == [tiedLowID.id, tiedHighID.id, late.id])
    }

    // MARK: - Rows that fail (GRDB)

    // The mock round-trips typed values, so it cannot hold a stored row that
    // fails to decode (`seedCorruptRow` only fakes a diagnostic). These cases
    // write raw SQL and are GRDB-only.

    @Test("observeSchedule drops an undecodable contact and its rows, and still delivers the rest")
    func observeScheduleDropsUndecodableContactAndItsRows() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabase()
        let repositories = GRDBRepositories(dbQueue: queue)
        let healthy = contractContact(id: try contractUUID(741), suffix: "schedule-healthy", tracked: true)
        let healthyRow = ScheduledReminder(
            id: try contractUUID(742),
            contactId: healthy.id,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_100),
            osNotificationId: "schedule-healthy"
        )
        try await repositories.contacts.upsert(healthy)
        try await repositories.reminders.upsert(healthyRow)
        let corruptID = try contractUUID(743)
        let corruptRowID = try contractUUID(744)
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO Contact
                        (id, systemContactRef, displayName, tracked, cadenceDays, preferredChannel, createdAt)
                    VALUES (?, ?, ?, 1, 14, 'not-a-channel', 1700000000)
                    """,
                arguments: [corruptID.uuidString, "schedule-corrupt", "Corrupt Contact"])
            try db.execute(
                sql: """
                    INSERT INTO ScheduledReminder
                        (id, contactId, kind, scheduledFor, osNotificationId, state)
                    VALUES (?, ?, 'cadence', 1800000100, 'schedule-corrupt', 'pending')
                    """,
                arguments: [corruptRowID.uuidString, corruptID.uuidString])
        }

        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())

        #expect(snapshot.contacts.map(\.id).contains(healthy.id))
        #expect(!snapshot.contacts.map(\.id).contains(corruptID))
        #expect(snapshot.reminders.map(\.id).contains(healthyRow.id))
        #expect(!snapshot.reminders.map(\.id).contains(corruptRowID))
    }

    /// Pins today's behavior: a row that fails to decode is dropped, and its
    /// contact and the contact's other rows still arrive. TF-07c decides the
    /// policy for such rows.
    @Test("observeSchedule drops a corrupt reminder row and still delivers its contact")
    func observeScheduleDropsCorruptReminderRowKeepsContact() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabase()
        let repositories = GRDBRepositories(dbQueue: queue)
        let contact = contractContact(id: try contractUUID(751), suffix: "schedule-bad-row", tracked: true)
        let goodRow = ScheduledReminder(
            id: try contractUUID(752),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_100),
            osNotificationId: "schedule-good-row"
        )
        try await repositories.contacts.upsert(contact)
        try await repositories.reminders.upsert(goodRow)
        let badRowID = try contractUUID(753)
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO ScheduledReminder
                        (id, contactId, kind, scheduledFor, osNotificationId, state)
                    VALUES (?, ?, 'not-a-kind', 1800000200, 'schedule-bad-row', 'pending')
                    """,
                arguments: [badRowID.uuidString, contact.id.uuidString])
        }

        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())

        #expect(snapshot.contacts.map(\.id).contains(contact.id))
        #expect(snapshot.reminders.map(\.id).contains(goodRow.id))
        #expect(!snapshot.reminders.map(\.id).contains(badRowID))
    }

    /// Follows `observeTrackedEndsStreamOnRealGRDBError`: a real read
    /// failure, no injected error. The snapshot needs the global window, so
    /// deleting that row makes the read throw. The stream must end, not hang
    /// or throw into the consumer, so a screen can clear its token and
    /// subscribe again on the next load.
    @Test("A real GRDB read error ends the schedule stream rather than hanging the consumer")
    func observeScheduleEndsStreamOnGRDBError() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabase()
        let repositories = GRDBRepositories(dbQueue: queue)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM ReminderWindow")
        }

        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()

        #expect(await iterator.next() == nil)
    }
}

/// The field-scoped contact writes `observeScheduleEmitsAfterContactFieldWrite`
/// replays against each backend.
enum ContactFieldWrite: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case lastInteracted
    case windowOverride
    case reconciledFields
    case deleteGroup

    var testDescription: String { rawValue }
}
