import Foundation
import Testing
@testable import Regards

/// Which pending rows the pass cancels, and when it leaves one alone (TF-07c,
/// §9 re-evaluation triggers, §13 orphans). Dates are New York local times
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
    /// looks at it. It was delivered, so it is history: kept, never
    /// cancelled. Passes on the code before this test was written.
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
    /// interaction in between. The fired row is the cycle's delivered
    /// reminder, so the contact is not nagged again: first inside the slot,
    /// then a day later, once the slot is over. Passes on the code before
    /// this test was written.
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
}
