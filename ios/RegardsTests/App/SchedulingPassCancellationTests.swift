import Foundation
import Testing
@testable import Regards

/// Which pending rows the pass cancels, which it marks fired instead, and when
/// it leaves one alone (TF-07c and TF-07e slice 2, §9 re-evaluation triggers
/// and "Notification fired", §13 orphans). Dates are New York local times
/// (`PassFixture`); the default window opens a slot at 18:00 every day.
struct SchedulingPassCancellationTests {

    @Test(
        "run(for:) cancels the pending row of a contact that is no longer tracked",
        arguments: RepositoryContractBackend.allCases
    )
    func runForAnUntrackedContactCancelsItsPendingRow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        let bystander = try await fixture.addContact(2)
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact) != nil)
        var untracked = contact
        untracked.tracked = false
        try await fixture.repositories.contacts.upsert(untracked)

        try await fixture.pass.run(for: contact.id)

        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(try await fixture.cadenceRow(bystander) != nil)
    }

    @Test(
        "A pending cadence row is cancelled when the contact's cadence is removed",
        arguments: RepositoryContractBackend.allCases
    )
    func cadenceRemovedCancelsThePendingRow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact) != nil)
        var withoutCadence = contact
        withoutCadence.cadenceDays = nil
        try await fixture.repositories.contacts.upsert(withoutCadence)

        try await fixture.pass.runFull()

        #expect(try await fixture.cadenceRow(contact) == nil)
    }

    /// The provider stops returning an occasion (Contacts dropped the
    /// birthday): its row is cancelled, the cadence row stays.
    @Test(
        "An occasion the provider no longer returns has its row cancelled",
        arguments: RepositoryContractBackend.allCases
    )
    func vanishedOccasionCancelsItsRow(backend: RepositoryContractBackend) async throws {
        let id = try contractUUID(7_001)
        let withBirthday = try await PassFixture(backend: backend, occasions: { _ in
            [ContactOccasion(contactId: id, kind: .birthday, monthDay: MonthDay(month: 6, day: 12))]
        })
        let contact = try await withBirthday.addContact(1)
        try await withBirthday.pass.runFull()
        #expect(try await withBirthday.occasionRow(contact, .birthday) != nil)
        let clock = withBirthday.clock
        let withoutBirthday = SchedulingPass(
            reminders: withBirthday.repositories.reminders,
            contacts: withBirthday.repositories.contacts,
            interactions: withBirthday.repositories.interactions,
            window: withBirthday.repositories.window,
            occasions: { _ in [] },
            clock: { clock.now() })

        try await withoutBirthday.runFull()

        #expect(try await withBirthday.occasionRow(contact, .birthday) == nil)
        #expect(try await withBirthday.cadenceRow(contact) != nil)
    }

    /// A second cadence row at an id the pass does not write (the deterministic
    /// id is the only one it owns) is stray, so it is cancelled.
    @Test("A pending row at a non-canonical id is cancelled", arguments: RepositoryContractBackend.allCases)
    func nonCanonicalIdRowIsCancelled(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        let stray = ScheduledReminder(
            contactId: contact.id, kind: .cadence, scheduledFor: PassFixture.at("2026-06-30 18:00"),
            osNotificationId: "contact-\(contact.id.uuidString)-stray")
        try await fixture.repositories.reminders.upsert(stray)

        try await fixture.pass.runFull()

        let pending = try await fixture.repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.map(\.id) == [fixture.cadenceID(contact)])
    }

    // MARK: - A due row outlives the cadence (§9 "Notification fired", Q3)

    /// Pin. The row was due when the cadence went away (removed, or set to 0,
    /// which is ineligible too), so the run marks it fired before the sweep
    /// looks at it. A due row is treated as delivered (§9), so it is history:
    /// kept as fired, never cancelled, and a second run writes nothing.
    @Test(
        "A due cadence row of a contact that lost its cadence stays fired and is not cancelled",
        arguments: RepositoryContractBackend.allCases, [nil, 0] as [Int?]
    )
    func dueRowOfAContactThatLostItsCadenceStaysFired(
        backend: RepositoryContractBackend, cadenceDays: Int?
    ) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        let slot = PassFixture.at("2026-06-10 18:00")
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == slot)
        fixture.setNow("2026-06-10 18:01")
        var withoutCadence = contact
        withoutCadence.cadenceDays = cadenceDays
        try await fixture.repositories.contacts.upsert(withoutCadence)

        try await fixture.pass.runFull()

        let fired = try #require(try await fixture.row(fixture.cadenceID(contact)))
        #expect(fired.state == .fired)
        #expect(fired.scheduledFor == slot)
        #expect(try await fixture.cadenceRow(contact) == nil)
        // The only change to the row is the fired mark: nothing was cancelled.
        let transitions = await fixture.reminders.transitionLog.filter { $0.id == fired.id }
        #expect(transitions == [TransitionCall(id: fired.id, from: .pending, to: .fired, applied: true)])
        let writes = await fixture.reminders.writeCount
        try await fixture.pass.runFull()
        #expect(try await fixture.row(fired.id) == fired)
        #expect(await fixture.reminders.writeCount == writes)
    }

    /// Pin. Continues the scenario above: the cadence comes back with no
    /// interaction in between. The fired row stands for the cycle's reminder,
    /// so the contact is not nagged again: first inside the slot, then a day
    /// later, once the slot is over. Neither run changes the row or writes
    /// anything.
    @Test(
        "A cadence set again after its due row fired does not bring the reminder back",
        arguments: RepositoryContractBackend.allCases
    )
    func returnedCadenceDoesNotReNagAfterAFiredRow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        let slot = PassFixture.at("2026-06-10 18:00")
        fixture.setNow("2026-06-10 18:01")
        var withoutCadence = contact
        withoutCadence.cadenceDays = nil
        try await fixture.repositories.contacts.upsert(withoutCadence)
        try await fixture.pass.runFull()
        let fired = try #require(try await fixture.row(fixture.cadenceID(contact)))
        #expect(fired.state == .fired)
        #expect(fired.scheduledFor == slot)
        let writes = await fixture.reminders.writeCount

        // The cadence is 7 days again; lastInteractedAt never moved.
        try await fixture.repositories.contacts.upsert(contact)
        try await fixture.pass.runFull()

        #expect(try await fixture.row(fired.id) == fired)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.reminders.writeCount == writes)

        // The slot is over, and the contact is still overdue.
        fixture.setNow("2026-06-11 10:00")
        try await fixture.pass.runFull()

        #expect(try await fixture.row(fired.id) == fired)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.reminders.writeCount == writes)
    }

    // MARK: - The orphan sweep (§9 "Notification fired", §13)

    /// Which entry point sweeps the rows of contacts the snapshot no longer holds.
    enum Sweep: CaseIterable, Sendable {
        case runFull, runFor
    }

    /// Two contacts each hold a pending cadence row: the first is due at
    /// 18:00, the second is 25 days out. Both leave the snapshot (archived,
    /// untracked) after 18:00 and no run covers them. The sweep marks the due
    /// row fired, since a due row is treated as delivered (§9), and cancels
    /// the future one. Both contacts come back a day later: the fired row is
    /// held, the future one is scheduled again.
    @Test(
        "The orphan sweep fires a due row and cancels a future one",
        arguments: RepositoryContractBackend.allCases, Sweep.allCases
    )
    func orphanSweepFiresADueRowAndCancelsAFutureOne(
        backend: RepositoryContractBackend, sweep: Sweep
    ) async throws {
        let fixture = try await PassFixture(backend: backend)
        let due = try await fixture.addContact(1)
        let future = try await fixture.addContact(2, cadenceDays: 30, lastInteracted: "2026-06-05 10:00")
        try await fixture.pass.runFull()
        let dueSlot = PassFixture.at("2026-06-10 18:00")
        let futureSlot = PassFixture.at("2026-07-05 18:00")
        #expect(try await fixture.cadenceRow(due)?.scheduledFor == dueSlot)
        #expect(try await fixture.cadenceRow(future)?.scheduledFor == futureSlot)
        fixture.setNow("2026-06-10 18:01")
        try await fixture.repositories.contacts.archive(id: due.id, at: fixture.clock.now())
        var untracked = future
        untracked.tracked = false
        try await fixture.repositories.contacts.upsert(untracked)

        switch sweep {
        case .runFull:
            try await fixture.pass.runFull()
        case .runFor:
            try await fixture.pass.run(for: due.id)
            // run(for:) sweeps only its own contact's rows.
            #expect(try await fixture.cadenceRow(future)?.state == .pending)
            try await fixture.pass.run(for: future.id)
        }

        let (dueID, futureID) = (fixture.cadenceID(due), fixture.cadenceID(future))
        let log = await fixture.reminders.transitionLog
        #expect(log.filter { $0.id == dueID } == [TransitionCall(id: dueID, from: .pending, to: .fired, applied: true)])
        #expect(log.filter { $0.id == futureID }
            == [TransitionCall(id: futureID, from: .pending, to: .cancelled, applied: true)])
        // A second sweep has nothing left to change.
        try await fixture.pass.runFull()
        let writes = await fixture.reminders.writeCount
        try await fixture.pass.runFull()
        #expect(await fixture.reminders.writeCount == writes)

        fixture.setNow("2026-06-11 10:00")
        try await fixture.repositories.contacts.upsert(due)
        try await fixture.repositories.contacts.upsert(future)
        try await fixture.pass.runFull()

        let delivered = try #require(try await fixture.row(dueID))
        #expect(delivered.state == .fired)
        #expect(delivered.scheduledFor == dueSlot)
        #expect(try await fixture.cadenceRow(due) == nil)
        #expect(try await fixture.cadenceRow(future)?.scheduledFor == futureSlot)
    }

    /// Boundary pin. A row is due at `scheduledFor <= now` (§9, run
    /// invariant), so the orphan sweep marks a row due exactly at now fired.
    /// A sweep that tested `<` would cancel it.
    @Test("An orphan row due exactly at now is marked fired", arguments: RepositoryContractBackend.allCases)
    func orphanRowDueExactlyNowIsFiredNotCancelled(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == PassFixture.at("2026-06-10 18:00"))
        fixture.setNow("2026-06-10 18:00")
        var untracked = contact
        untracked.tracked = false
        try await fixture.repositories.contacts.upsert(untracked)

        try await fixture.pass.runFull()

        let id = fixture.cadenceID(contact)
        let transitions = await fixture.reminders.transitionLog.filter { $0.id == id }
        #expect(transitions == [TransitionCall(id: id, from: .pending, to: .fired, applied: true)])
        // The schedule snapshot hides an untracked contact's rows, so track the
        // contact again (no run) to read the stored state.
        try await fixture.repositories.contacts.upsert(contact)
        #expect(try await fixture.row(id)?.state == .fired)
    }

    /// The contact is untracked right after its 18:00 slot delivered. Tracked
    /// again, in the same slot or the next day, it is overdue on the same
    /// cycle, so the fired row holds and the run writes nothing.
    @Test(
        "A re-tracked contact is not notified again for the slot that was delivered",
        arguments: RepositoryContractBackend.allCases, ["2026-06-10 18:30", "2026-06-11 10:00"]
    )
    func reTrackedContactIsNotNotifiedAgainForItsDeliveredSlot(
        backend: RepositoryContractBackend, returnAt: String
    ) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        fixture.setNow("2026-06-10 18:01")
        var untracked = contact
        untracked.tracked = false
        try await fixture.repositories.contacts.upsert(untracked)
        try await fixture.pass.run(for: contact.id)
        fixture.setNow(returnAt)
        try await fixture.pass.runFull()
        try await fixture.repositories.contacts.upsert(contact)
        let writes = await fixture.reminders.writeCount

        try await fixture.pass.runFull()

        let delivered = try #require(try await fixture.row(fixture.cadenceID(contact)))
        #expect(delivered.state == .fired)
        #expect(delivered.scheduledFor == PassFixture.at("2026-06-10 18:00"))
        #expect(delivered.snoozedUntil == nil)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.reminders.writeCount == writes)
    }

    /// A birthday at 09:00 and a cadence row (moved to 06-11 by contract 6)
    /// are both pending when the contact is untracked at 09:30. The sweep
    /// fires the due birthday and cancels the future cadence row. Tracked
    /// again at 10:00, the birthday is not delivered a second time.
    @Test(
        "The orphan sweep fires a due occasion row and cancels a future cadence row",
        arguments: RepositoryContractBackend.allCases
    )
    func orphanSweepFiresADueOccasionAndCancelsAFutureCadenceRow(backend: RepositoryContractBackend) async throws {
        let id = try contractUUID(7_001)
        let fixture = try await PassFixture(backend: backend, now: "2026-06-10 08:00", occasions: { _ in
            [ContactOccasion(contactId: id, kind: .birthday, monthDay: MonthDay(month: 6, day: 10))]
        })
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        let birthdayID = SchedulingPass.reminderID(contactId: contact.id, kind: .birthday)
        let cadenceID = fixture.cadenceID(contact)
        let birthdaySlot = PassFixture.at("2026-06-10 09:00")
        let cadenceSlot = PassFixture.at("2026-06-11 18:00")
        #expect(try await fixture.occasionRow(contact, .birthday)?.scheduledFor == birthdaySlot)
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == cadenceSlot)
        fixture.setNow("2026-06-10 09:30")
        var untracked = contact
        untracked.tracked = false
        try await fixture.repositories.contacts.upsert(untracked)

        try await fixture.pass.run(for: contact.id)

        let log = await fixture.reminders.transitionLog
        #expect(log.filter { $0.id == birthdayID }
            == [TransitionCall(id: birthdayID, from: .pending, to: .fired, applied: true)])
        #expect(log.filter { $0.id == cadenceID }
            == [TransitionCall(id: cadenceID, from: .pending, to: .cancelled, applied: true)])

        fixture.setNow("2026-06-10 10:00")
        try await fixture.repositories.contacts.upsert(contact)
        try await fixture.pass.runFull()

        let birthday = try #require(try await fixture.row(birthdayID))
        #expect(birthday.state == .fired)
        #expect(birthday.scheduledFor == birthdaySlot)
        #expect(try await fixture.occasionRow(contact, .birthday) == nil)
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == cadenceSlot)
    }
}
