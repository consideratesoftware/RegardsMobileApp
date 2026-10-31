import Foundation
import Testing
@testable import Regards

/// `SchedulingPass.runFull()` and `run(for:)` (TF-07c, §9, §13): the rows the
/// pass derives for every tracked contact, that a second run writes nothing,
/// zero-capacity windows, orphans, the lock, and corrupt rows. Each test runs
/// on the GRDB store and the seeded mock; dates are New York local times
/// (`PassFixture`). Corrupt rows are in `SchedulingPassCorruptRowTests`.
struct SchedulingPassRunFullTests {

    private actor SnoozeFinished {
        private(set) var isMarked = false
        func mark() { isMarked = true }
    }

    /// 5 contacts that exercise each branch of the derivation, plus one
    /// birthday. Returns them in order: overdue, future, snoozed, override,
    /// zero-capacity.
    private static func seedFiveContacts(
        _ fixture: PassFixture
    ) async throws -> (overdue: Contact, future: Contact, snoozed: Contact, override: Contact, zero: Contact) {
        let overdue = try await fixture.addContact(1, cadenceDays: 7, lastInteracted: "2026-05-01 10:00")
        let future = try await fixture.addContact(2, cadenceDays: 30, lastInteracted: "2026-06-05 10:00")
        let snoozed = try await fixture.addContact(3, cadenceDays: 7, lastInteracted: "2026-05-01 10:00")
        let override = try await fixture.addContact(
            4, cadenceDays: 7, lastInteracted: "2026-05-01 10:00",
            override: PassFixture.eveningWindow(start: 20, end: 21))
        // Quiet hours 17:00-20:00 cover the whole 18:00-19:00 range.
        let zero = try await fixture.addContact(
            5, cadenceDays: 7, lastInteracted: "2026-05-01 10:00",
            override: PassFixture.eveningWindow(
                quiet: TimeRange(start: TimeOfDay(hour: 17), end: TimeOfDay(hour: 20))))
        try await fixture.repositories.reminders.upsert(ScheduledReminder(
            id: fixture.cadenceID(snoozed),
            contactId: snoozed.id,
            kind: .cadence,
            scheduledFor: PassFixture.at("2026-06-17 18:00"),
            osNotificationId: "contact-\(snoozed.id.uuidString)-cadence",
            snoozedUntil: PassFixture.at("2026-06-17 10:00")))
        return (overdue, future, snoozed, override, zero)
    }

    @Test(
        "A second runFull on the same clock makes no repository writes",
        arguments: RepositoryContractBackend.allCases
    )
    func runFullTwiceIsNoOp(backend: RepositoryContractBackend) async throws {
        let futureID = try contractUUID(7_002)
        let fixture = try await PassFixture(backend: backend, occasions: { _ in
            [ContactOccasion(contactId: futureID, kind: .birthday, monthDay: MonthDay(month: 6, day: 12))]
        })
        let cast = try await Self.seedFiveContacts(fixture)

        try await fixture.pass.runFull()

        let firstRunWrites = await fixture.reminders.writeCount
        #expect(firstRunWrites > 0, "the first run has rows to write")
        #expect(try await fixture.cadenceRow(cast.overdue)?.scheduledFor == PassFixture.at("2026-06-10 18:00"))
        #expect(try await fixture.cadenceRow(cast.future)?.scheduledFor == PassFixture.at("2026-07-05 18:00"))
        #expect(try await fixture.cadenceRow(cast.snoozed)?.scheduledFor == PassFixture.at("2026-06-17 18:00"))
        #expect(try await fixture.cadenceRow(cast.override)?.scheduledFor == PassFixture.at("2026-06-10 20:00"))
        #expect(try await fixture.cadenceRow(cast.zero) == nil)
        #expect(try await fixture.occasionRow(cast.future, .birthday)?.scheduledFor
                == PassFixture.at("2026-06-12 09:00"))

        try await fixture.pass.runFull()

        #expect(await fixture.reminders.writeCount == firstRunWrites)
    }

    /// No re-nag (§9, owner ruling 5): once a cadence row's time has passed,
    /// a contact who is still overdue keeps that row. Re-deriving it would
    /// move it to the next window's slot on every later run.
    @Test(
        "A cadence row whose slot has started is left alone while the contact is still overdue",
        arguments: RepositoryContractBackend.allCases
    )
    func dueCadenceRowIsNotRewrittenOnALaterRun(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        let due = try #require(try await fixture.cadenceRow(contact))
        #expect(due.scheduledFor == PassFixture.at("2026-06-10 18:00"))
        let writesBefore = await fixture.reminders.writeCount

        fixture.setNow("2026-06-10 19:30")
        try await fixture.pass.runFull()

        #expect(try await fixture.cadenceRow(contact) == due)
        #expect(await fixture.reminders.writeCount == writesBefore)
    }

    // MARK: - Zero capacity (R4, §9 contract 2)

    @Test(
        "A contact whose effective window can never fire gets no row and is listed",
        arguments: RepositoryContractBackend.allCases
    )
    func zeroCapacityContactGetsNoRow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let cast = try await Self.seedFiveContacts(fixture)

        try await fixture.pass.runFull()

        #expect(try await fixture.cadenceRow(cast.zero) == nil)
        #expect(await fixture.pass.zeroCapacityContactIds == [cast.zero.id])
    }

    @Test(
        "A pending row is cancelled when its contact's window loses all capacity",
        arguments: RepositoryContractBackend.allCases
    )
    func zeroCapacityCancelsThePendingRow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact) != nil)
        _ = try await fixture.repositories.contacts.updateReminderWindowOverride(
            id: contact.id,
            window: PassFixture.eveningWindow(quiet: TimeRange(start: TimeOfDay(hour: 17), end: TimeOfDay(hour: 20))))

        try await fixture.pass.run(for: contact.id)

        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.reminders.transitions == 1)
        #expect(await fixture.pass.zeroCapacityContactIds == [contact.id])
    }

    /// The slot has already started, so the no-re-nag rule would keep the due
    /// row. A window that can no longer fire at all wins over it: the row is
    /// cancelled and the contact is listed for the Settings badge.
    @Test(
        "A due row is cancelled and the contact recorded when its window loses all capacity",
        arguments: RepositoryContractBackend.allCases
    )
    func zeroCapacityWithADueRowCancelsAndRecords(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == PassFixture.at("2026-06-10 18:00"))
        fixture.setNow("2026-06-10 18:30")
        _ = try await fixture.repositories.contacts.updateReminderWindowOverride(
            id: contact.id,
            window: PassFixture.eveningWindow(quiet: TimeRange(start: TimeOfDay(hour: 17), end: TimeOfDay(hour: 20))))

        try await fixture.pass.run(for: contact.id)

        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.pass.zeroCapacityContactIds == [contact.id])
    }

    @Test(
        "run(for:) updates the zero-capacity list for that contact only",
        arguments: RepositoryContractBackend.allCases
    )
    func runForUpdatesTheBadgeForOneContact(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let cast = try await Self.seedFiveContacts(fixture)
        try await fixture.pass.runFull()
        #expect(await fixture.pass.zeroCapacityContactIds == [cast.zero.id])

        _ = try await fixture.repositories.contacts.updateReminderWindowOverride(
            id: cast.zero.id, window: PassFixture.eveningWindow())
        try await fixture.pass.run(for: cast.zero.id)
        #expect(await fixture.pass.zeroCapacityContactIds.isEmpty)
        #expect(try await fixture.cadenceRow(cast.zero)?.scheduledFor == PassFixture.at("2026-06-10 18:00"))

        _ = try await fixture.repositories.contacts.updateReminderWindowOverride(
            id: cast.override.id,
            window: PassFixture.eveningWindow(quiet: TimeRange(start: TimeOfDay(hour: 17), end: TimeOfDay(hour: 20))))
        try await fixture.pass.run(for: cast.override.id)
        #expect(await fixture.pass.zeroCapacityContactIds == [cast.override.id])
    }

    // MARK: - run(for:) scope

    /// An override save re-runs the one contact (§9 re-evaluation triggers).
    /// A row for another contact that is stale stays stale: only `runFull`
    /// repairs it.
    @Test(
        "run(for:) reschedules that contact and leaves every other row alone",
        arguments: RepositoryContractBackend.allCases
    )
    func runForTouchesOnlyThatContact(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let edited = try await fixture.addContact(1)
        let bystander = try await fixture.addContact(2)
        let staleBystanderRow = ScheduledReminder(
            id: fixture.cadenceID(bystander),
            contactId: bystander.id,
            kind: .cadence,
            scheduledFor: PassFixture.at("2026-06-30 18:00"),
            osNotificationId: "contact-\(bystander.id.uuidString)-cadence")
        try await fixture.repositories.reminders.upsert(staleBystanderRow)
        let writesBefore = await fixture.reminders.upserts
        _ = try await fixture.repositories.contacts.updateReminderWindowOverride(
            id: edited.id, window: PassFixture.eveningWindow(start: 20, end: 21))

        try await fixture.pass.run(for: edited.id)

        #expect(try await fixture.cadenceRow(edited)?.scheduledFor == PassFixture.at("2026-06-10 20:00"))
        #expect(try await fixture.cadenceRow(bystander) == staleBystanderRow)
        #expect(await fixture.reminders.upserts == writesBefore + 1)
    }

    // MARK: - Orphans (§13)

    enum Orphan: String, CaseIterable, Sendable {
        case untracked
        case archived
    }

    @Test(
        "A pending row for a contact that is no longer tracked or active is cancelled",
        arguments: RepositoryContractBackend.allCases, Orphan.allCases
    )
    func orphanedPendingRowIsCancelled(backend: RepositoryContractBackend, orphan: Orphan) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        let kept = try await fixture.addContact(2)
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact) != nil)
        switch orphan {
        case .untracked:
            var untracked = contact
            untracked.tracked = false
            try await fixture.repositories.contacts.upsert(untracked)
        case .archived:
            try await fixture.repositories.contacts.archive(id: contact.id, at: PassFixture.at("2026-06-10 09:00"))
        }

        try await fixture.pass.runFull()

        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(try await fixture.cadenceRow(kept) != nil)
        #expect(await fixture.pass.zeroCapacityContactIds.isEmpty)
    }

    @Test(
        "A 0-day cadence is ineligible: no row from the pass and no snooze",
        arguments: RepositoryContractBackend.allCases
    )
    func zeroCadenceIsIneligible(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1, cadenceDays: 0)

        try await fixture.pass.runFull()
        let snoozed = try await fixture.pass.snooze(contactId: contact.id)

        #expect(!snoozed)
        #expect(try await fixture.repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    // MARK: - Lock (R59)

    /// A Snooze tap that arrives while `runFull` has decided its row but not
    /// written it waits for the run (one FIFO lock), then writes. Without the
    /// lock the run's write lands after the snooze and erases it.
    @Test(
        "A snooze tapped during runFull completes after it and keeps its floor",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeDuringRunFullCompletes(backend: RepositoryContractBackend) async throws {
        let gate = AsyncGate()
        let fixture = try await PassFixture(backend: backend, upsertGate: gate)
        let contact = try await fixture.addContact(1)

        let run = Task { try await fixture.pass.runFull() }
        await gate.waitUntilArrived()
        let finished = SnoozeFinished()
        let snooze = Task {
            let wrote = try await fixture.pass.snooze(contactId: contact.id)
            await finished.mark()
            return wrote
        }
        // A negative wait: with the lock the snooze cannot finish until the run
        // does, so this loop is expected to run all 3_000 turns (milliseconds)
        // and move on. Without the lock the snooze finishes within a few turns
        // and the loop exits early. The bound is the suite's `Task.yield()`
        // polling convention; nothing here sleeps or depends on timing for a
        // pass, only for how quickly a mutant is caught.
        var turns = 0
        while turns < 3_000, !(await finished.isMarked) {
            await Task.yield()
            turns += 1
        }
        await gate.open()
        try await run.value
        let snoozed = try await snooze.value

        #expect(snoozed)
        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.snoozedUntil == PassFixture.at("2026-06-17 10:00"))
        #expect(row.scheduledFor == PassFixture.at("2026-06-17 18:00"))
    }

    /// A pending row due at 18:00 for a contact overdue by a 7-day cadence.
    /// Lengthening the cadence to 60 days makes the contact not overdue, so
    /// the no-re-nag guard no longer holds and the row follows the new due date.
    @Test(
        "A due row is derived again when the cadence lengthens past it",
        arguments: RepositoryContractBackend.allCases
    )
    func dueRowIsRederivedWhenTheCadenceLengthens(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1, cadenceDays: 7, lastInteracted: "2026-05-01 10:00")
        try await fixture.pass.runFull()
        fixture.setNow("2026-06-10 18:30")
        var longer = contact
        longer.cadenceDays = 60
        try await fixture.repositories.contacts.upsert(longer)

        try await fixture.pass.runFull()

        // 2026-05-01 10:00 plus 60 days is 06-30 10:00.
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == PassFixture.at("2026-06-30 18:00"))
    }

    /// R55: the window is read on every run. Moving the global window to
    /// another zone moves the same wall-clock slot with it.
    @Test(
        "runFull derives slots in the zone of the window as stored now",
        arguments: RepositoryContractBackend.allCases
    )
    func runFullUsesTheCurrentWindowZone(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == PassFixture.at("2026-06-10 18:00"))

        try await fixture.repositories.window.saveGlobal(PassFixture.eveningWindow(zone: "Europe/London"))
        try await fixture.pass.runFull()

        // 18:00 BST on 06-10 is 17:00 UTC.
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor
                == ISO8601DateFormatter().date(from: "2026-06-10T17:00:00Z"))
    }
}
