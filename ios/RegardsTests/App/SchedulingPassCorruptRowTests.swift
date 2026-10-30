import Foundation
import GRDB
import Testing
@testable import Regards

/// Corrupt stored rows (TF-07c, §9a "Corrupt rows"): the pass reads one
/// `observeSchedule()` snapshot, which drops what it can't decode, and
/// follows that. One bad row never stops scheduling for everyone else.
///
/// These tests plant undecodable rows below the repository seam, which needs
/// raw SQL, so this file imports GRDB outside `Data/`.
struct SchedulingPassCorruptRowTests {

    private struct World {
        let queue: DatabaseQueue
        let repositories: GRDBRepositories
        let clock: MutableClock
        let pass: SchedulingPass

        init() async throws {
            queue = try DatabaseFactory.makeInMemoryDatabase()
            repositories = GRDBRepositories(dbQueue: queue)
            try await repositories.window.saveGlobal(PassFixture.eveningWindow())
            let clock = MutableClock(PassFixture.at("2026-06-10 10:00"))
            self.clock = clock
            pass = SchedulingPass(
                reminders: repositories.reminders,
                contacts: repositories.contacts,
                window: repositories.window,
                occasions: { _ in [] },
                clock: { clock.now() })
        }

        func addContact(_ number: Int, tracked: Bool = true) async throws -> Contact {
            let contact = Contact(
                id: try contractUUID(7_100 + number), systemContactRef: "pass-corrupt-\(number)",
                displayName: "Corrupt \(number)", tracked: tracked, cadenceDays: 7,
                lastInteractedAt: PassFixture.at("2026-05-01 10:00"))
            try await repositories.contacts.upsert(contact)
            return contact
        }

        /// A pending row whose `kind` no `ReminderKind` decodes.
        func insertUndecodableRow(for contact: Contact, id: UUID) async throws {
            try await queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO ScheduledReminder
                            (id, contactId, kind, scheduledFor, osNotificationId, state)
                        VALUES (?, ?, 'not-a-kind', 1800000200, 'corrupt-row', 'pending')
                        """,
                    arguments: [id.uuidString, contact.id.uuidString])
            }
        }
    }

    /// The pass follows the snapshot's drop policy: an undecodable contact is
    /// invisible to it, and its pending row is left as stored, neither
    /// rewritten nor cancelled.
    @Test("An undecodable contact does not stop the run and keeps its stored row")
    func corruptContactDoesNotStopTheRun() async throws {
        let world = try await World()
        let corrupt = try await world.addContact(1)
        let healthy = try await world.addContact(2)
        let storedRow = ScheduledReminder(
            contactId: corrupt.id, kind: .cadence, scheduledFor: PassFixture.at("2026-06-30 18:00"),
            osNotificationId: "contact-\(corrupt.id.uuidString)-cadence")
        try await world.repositories.reminders.upsert(storedRow)
        try await world.queue.write { db in
            try db.execute(
                sql: "UPDATE Contact SET phonesJson = ? WHERE id = ?",
                arguments: ["null", corrupt.id.uuidString])
        }

        try await world.pass.runFull()

        let healthyRow = try await world.repositories.reminders.fetchPending(forContact: healthy.id).first
        #expect(healthyRow?.scheduledFor == PassFixture.at("2026-06-10 18:00"))
        #expect(try await world.repositories.reminders.fetchPending(forContact: corrupt.id) == [storedRow])
    }

    /// `fetchAllPending()` fails while any pending row is undecodable, so the
    /// orphan sweep that depends on it is skipped, and the run still
    /// completes and schedules everyone else. Once the bad row is gone the
    /// sweep resumes and cancels the orphan.
    @Test("An undecodable reminder row skips the orphan sweep but not the run")
    func corruptReminderRowSkipsOnlyTheOrphanSweep() async throws {
        let world = try await World()
        let healthy = try await world.addContact(1)
        let orphan = try await world.addContact(2)
        try await world.pass.runFull()
        #expect(try await world.repositories.reminders.fetchPending(forContact: orphan.id).count == 1)
        var untracked = orphan
        untracked.tracked = false
        try await world.repositories.contacts.upsert(untracked)
        let badRowID = try contractUUID(7_190)
        try await world.insertUndecodableRow(for: healthy, id: badRowID)
        let fresh = try await world.addContact(3)

        try await world.pass.runFull()

        #expect(try await world.repositories.reminders.fetchPending(forContact: fresh.id).count == 1,
                "scheduling still ran for a contact added after the bad row")
        #expect(try await world.queue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM ScheduledReminder WHERE contactId = ? AND state = 'pending'",
                arguments: [orphan.id.uuidString])
        } == 1, "the orphan's row is still pending while the sweep is skipped")

        try await world.queue.write { db in
            try db.execute(sql: "DELETE FROM ScheduledReminder WHERE id = ?", arguments: [badRowID.uuidString])
        }
        try await world.pass.runFull()
        #expect(try await world.repositories.reminders.fetchPending(forContact: orphan.id).isEmpty)
    }

    /// The pass replaces an undecodable row only at an id it writes. The
    /// cadence id is one, so the bad row there is overwritten by the upsert.
    @Test("An undecodable row at the cadence id is replaced by the pass's own row")
    func undecodableRowAtTheCadenceIdIsReplaced() async throws {
        let world = try await World()
        let contact = try await world.addContact(1)
        let cadenceID = SchedulingPass.reminderID(contactId: contact.id, kind: .cadence)
        try await world.insertUndecodableRow(for: contact, id: cadenceID)

        try await world.pass.runFull()

        let pending = try await world.repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.map(\.id) == [cadenceID])
        #expect(pending.first?.scheduledFor == PassFixture.at("2026-06-10 18:00"))
    }
}
