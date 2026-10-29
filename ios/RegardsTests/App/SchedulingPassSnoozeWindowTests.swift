import Foundation
import Testing
@testable import Regards

/// Snooze through the contact's effective window (TF-07c, R55, R57's write
/// half, owner ruling 1). The row keeps the raw floor (`snoozedUntil`, tap
/// time plus 7 calendar days) and `scheduledFor` is the first slot at or
/// after it. Dates are New York local times (`PassFixture`) unless noted; the
/// default window opens a slot at 18:00 every day.
struct SchedulingPassSnoozeWindowTests {

    @Test(
        "A snooze lands in the contact's override window, not the global one",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeResolvesThroughEffectiveWindow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, now: "2026-06-09 10:00")
        // Mondays 18:00-19:00 only; the global window is every day.
        let contact = try await fixture.addContact(
            1, override: PassFixture.eveningWindow(days: .monday))

        let wrote = try await fixture.pass.snooze(contactId: contact.id)

        #expect(wrote)
        let row = try #require(try await fixture.cadenceRow(contact))
        // Tuesday 06-09 plus 7 days is Tuesday 06-16; the next Monday slot is 06-22.
        #expect(row.snoozedUntil == PassFixture.at("2026-06-16 10:00"))
        #expect(row.scheduledFor == PassFixture.at("2026-06-22 18:00"))
        #expect(row.state == .pending)
    }

    /// Owner ruling 1: the anchor is the tap, not the time the notification
    /// fired. A snooze tapped 8 days after the reminder fired must not land
    /// in the past (§9's old `firedAt + 7d` fired at once).
    @Test(
        "A snooze counts 7 days from the tap, not from when the reminder fired",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeAnchorIsTheTapTime(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        try await fixture.repositories.reminders.upsert(ScheduledReminder(
            id: fixture.cadenceID(contact),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: PassFixture.at("2026-06-02 18:00"),
            osNotificationId: "contact-\(contact.id.uuidString)-cadence",
            state: .fired))

        _ = try await fixture.pass.snooze(contactId: contact.id)

        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.snoozedUntil == PassFixture.at("2026-06-17 10:00"))
        #expect(row.scheduledFor == PassFixture.at("2026-06-17 18:00"))
    }

    /// The pass reads `snoozedUntil` from the pending row, so a run neither
    /// loses the snooze nor moves it, now or after more days have passed.
    @Test("A snooze survives runFull before its slot arrives", arguments: RepositoryContractBackend.allCases)
    func snoozeSurvivesRunFull(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        _ = try await fixture.pass.snooze(contactId: contact.id)
        let snoozed = try #require(try await fixture.cadenceRow(contact))

        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact) == snoozed)

        fixture.setNow("2026-06-13 10:00")
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact) == snoozed)
    }

    @Test(
        "Editing the global window moves a snoozed row to the new window's slot after the floor",
        arguments: RepositoryContractBackend.allCases
    )
    func windowEditReResolvesSnooze(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        _ = try await fixture.pass.snooze(contactId: contact.id)
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == PassFixture.at("2026-06-17 18:00"))

        try await fixture.repositories.window.saveGlobal(PassFixture.eveningWindow(start: 20, end: 21))
        try await fixture.pass.runFull()

        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.scheduledFor == PassFixture.at("2026-06-17 20:00"))
        #expect(row.snoozedUntil == PassFixture.at("2026-06-17 10:00"))
    }

    /// R55: the pass reads the window on every call. 2026-03-05 12:00 UTC is
    /// 07:00 in New York and 12:00 in London; 7 calendar days later New York
    /// has changed clocks (03-08) and London has not (03-29), so the zones
    /// give floors an hour apart.
    @Test(
        "A snooze counts its 7 days in the zone of the window as stored now",
        arguments: RepositoryContractBackend.allCases
    )
    func passReadsWindowTimeZonePerRun(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, now: "2026-03-05 07:00")
        let contact = try await fixture.addContact(1, lastInteracted: "2026-02-01 10:00")
        try await fixture.pass.runFull()
        let london = PassFixture.eveningWindow(start: 12, end: 13, zone: "Europe/London")
        try await fixture.repositories.window.saveGlobal(london)

        _ = try await fixture.pass.snooze(contactId: contact.id)

        let row = try #require(try await fixture.cadenceRow(contact))
        let utc = ISO8601DateFormatter()
        #expect(row.snoozedUntil == utc.date(from: "2026-03-12T12:00:00Z"))
        #expect(row.scheduledFor == utc.date(from: "2026-03-12T12:00:00Z"))
    }
}
