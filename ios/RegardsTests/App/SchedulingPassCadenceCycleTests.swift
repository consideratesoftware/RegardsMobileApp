import Foundation
import Testing
@testable import Regards

/// The cadence cycle in rows (TF-07c, §9): what a fired row, a caught-up and
/// a failed caught-up leave behind, and what the next run derives from them.
/// Dates are New York local times (`PassFixture`): the default window opens a
/// slot at 18:00 every day.
struct SchedulingPassCadenceCycleTests {

    private static func firedRow(
        for contact: Contact, scheduledFor: String, in fixture: PassFixture
    ) -> ScheduledReminder {
        ScheduledReminder(
            id: fixture.cadenceID(contact),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: PassFixture.at(scheduledFor),
            osNotificationId: "contact-\(contact.id.uuidString)-cadence",
            state: .fired)
    }

    // MARK: - Fired rows (§9 "Notification fired")

    @Test("A fired row stays fired while the contact is still overdue", arguments: RepositoryContractBackend.allCases)
    func firedRowNotRescheduled(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        let fired = Self.firedRow(for: contact, scheduledFor: "2026-06-09 18:00", in: fixture)
        try await fixture.repositories.reminders.upsert(fired)

        try await fixture.pass.runFull()

        #expect(try await fixture.row(fired.id) == fired)
        #expect(try await fixture.cadenceRow(contact) == nil)
    }

    @Test(
        "A fired row is replaced by a pending one once the contact has been caught up since",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpRePendsFiredRow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        // Talked this morning, after the 06-09 18:00 reminder fired.
        let contact = try await fixture.addContact(1, cadenceDays: 7, lastInteracted: "2026-06-10 09:00")
        try await fixture.repositories.reminders.upsert(
            Self.firedRow(for: contact, scheduledFor: "2026-06-09 18:00", in: fixture))

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.id == fixture.cadenceID(contact))
        #expect(row.state == .pending)
        #expect(row.scheduledFor == PassFixture.at("2026-06-17 18:00"))
        #expect(row.snoozedUntil == nil)
    }

    // MARK: - Caught up

    enum Entry: String, CaseIterable, Sendable {
        case runFull
        case runForContact
    }

    /// `transitionState` leaves a `userCaughtUp` row out of every snapshot, so
    /// the next run writes a fresh pending row for the next cycle: the new
    /// anchor plus the cadence, resolved into the window.
    @Test(
        "After Caught up the next run writes the next cadence row from the new anchor",
        arguments: RepositoryContractBackend.allCases, Entry.allCases
    )
    func caughtUpWritesNextCadenceRow(backend: RepositoryContractBackend, entry: Entry) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1, cadenceDays: 14)
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == PassFixture.at("2026-06-10 18:00"))

        let cleared = try await fixture.pass.caughtUp(contactId: contact.id)
        _ = try await fixture.repositories.contacts.updateLastInteractedAt(
            id: contact.id, at: PassFixture.at("2026-06-10 10:00"))
        #expect(cleared)
        #expect(try await fixture.cadenceRow(contact) == nil)
        switch entry {
        case .runFull: try await fixture.pass.runFull()
        case .runForContact: try await fixture.pass.run(for: contact.id)
        }

        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.state == .pending)
        #expect(row.scheduledFor == PassFixture.at("2026-06-24 18:00"))
        #expect(row.snoozedUntil == nil)
    }

    /// Tech-lead ruling: `caughtUp` is state-only, so a failed caught-up's
    /// restore brings the snooze back with its floor, and the next run keeps
    /// it. If the transition cleared the floor, `runFull` would pull the
    /// contact back to the overdue slot and lose the snooze.
    @Test(
        "A failed Caught up restores the snooze and the next run keeps its floor",
        arguments: RepositoryContractBackend.allCases
    )
    func failedCaughtUpKeepsSnoozeFloor(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        #expect(try await fixture.pass.snooze(contactId: contact.id))
        let snoozed = try #require(try await fixture.cadenceRow(contact))
        #expect(snoozed.snoozedUntil == PassFixture.at("2026-06-17 10:00"))

        #expect(try await fixture.pass.caughtUp(contactId: contact.id))
        let logging = InteractionLogging(
            contacts: fixture.repositories.contacts, interactions: StubInteractionRepository.failing())
        await #expect(throws: (any Error).self) {
            try await logging.markCaughtUp(contactId: contact.id, at: PassFixture.at("2026-06-10 10:00"))
        }
        try await fixture.pass.restorePendingAfterFailedCaughtUp(contactId: contact.id)
        try await fixture.pass.runFull()

        #expect(try await fixture.cadenceRow(contact) == snoozed)
        #expect(snoozed.scheduledFor == PassFixture.at("2026-06-17 18:00"))
    }
}
