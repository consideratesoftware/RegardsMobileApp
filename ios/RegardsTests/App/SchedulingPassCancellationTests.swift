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
}
