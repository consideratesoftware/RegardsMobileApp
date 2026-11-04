import Foundation
import Testing
@testable import Regards

/// Fired rows (TF-07e, §9 "Notification fired"): each run marks the rows
/// whose time has come as fired, and a fired row is history that the pass
/// neither re-delivers nor re-nags. Dates are New York local times
/// (`PassFixture`) unless a test sets its own zone. The default window opens a
/// slot at 18:00 every day.
struct SchedulingPassFiredRowTests {

    private static func pendingCadenceRow(
        for contact: Contact, at scheduledFor: Date, in fixture: PassFixture
    ) -> ScheduledReminder {
        ScheduledReminder(
            id: fixture.cadenceID(contact),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: scheduledFor,
            osNotificationId: "contact-\(contact.id.uuidString)-cadence")
    }

    /// Quiet hours 17:00-20:00 cover the whole 18:00-19:00 range.
    private static let zeroCapacityWindow = PassFixture.eveningWindow(
        quiet: TimeRange(start: TimeOfDay(hour: 17), end: TimeOfDay(hour: 20)))

    // MARK: - Marking

    /// One hour ago and exactly now are both "has come": the rule is
    /// `scheduledFor <= now`. The second run proves the mark is a state
    /// change, not a rewrite the next run repeats.
    @Test(
        "A pending row whose time has come is marked fired once, with its slot unchanged",
        arguments: RepositoryContractBackend.allCases, [-3_600.0, 0.0]
    )
    func dueRowsAreMarkedFiredAtRunStart(
        backend: RepositoryContractBackend, secondsFromNow: TimeInterval
    ) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        let pending = Self.pendingCadenceRow(
            for: contact, at: fixture.clock.now().addingTimeInterval(secondsFromNow), in: fixture)
        try await fixture.repositories.reminders.upsert(pending)
        var fired = pending
        fired.state = .fired

        try await fixture.pass.runFull()

        #expect(try await fixture.row(pending.id) == fired)
        #expect(try await fixture.cadenceRow(contact) == nil)
        let writes = await fixture.reminders.writeCount
        try await fixture.pass.runFull()
        #expect(try await fixture.row(pending.id) == fired)
        #expect(await fixture.reminders.writeCount == writes)
    }

    // MARK: - Zero capacity round trip (contract 2)

    /// The slot in progress was delivered: the row is fired at its start `S`.
    /// A window that loses all capacity and then regains it must not turn that
    /// delivered slot into a new pending row, which would deliver it again.
    @Test(
        "A zero-capacity round trip leaves the delivered slot fired and makes no new row",
        arguments: RepositoryContractBackend.allCases
    )
    func zeroCapacityRoundTripDoesNotReDeliverThePastSlot(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, now: "2026-06-10 18:30")
        let contact = try await fixture.addContact(1)
        let slotStart = PassFixture.at("2026-06-10 18:00")
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == slotStart, "the overdue contact joined the slot")
        fixture.setNow("2026-06-10 18:40")

        _ = try await fixture.repositories.contacts.updateReminderWindowOverride(
            id: contact.id, window: Self.zeroCapacityWindow)
        try await fixture.pass.run(for: contact.id)

        let delivered = try #require(try await fixture.row(fixture.cadenceID(contact)))
        #expect(delivered.state == .fired)
        #expect(delivered.scheduledFor == slotStart)
        #expect(await fixture.pass.zeroCapacityContactIds == [contact.id])
        let writes = await fixture.reminders.writeCount

        _ = try await fixture.repositories.contacts.updateReminderWindowOverride(id: contact.id, window: nil)
        try await fixture.pass.run(for: contact.id)

        #expect(try await fixture.row(fixture.cadenceID(contact)) == delivered)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.pass.zeroCapacityContactIds.isEmpty)
        #expect(await fixture.reminders.writeCount == writes)
    }

    // MARK: - No re-nag (§9, owner ruling 5)

    /// America/Los_Angeles, Sunday 2026-11-01, is 25 hours long (PDT ends at
    /// 02:00). With a 1-day cadence and a range of 00:00-23:59, a contact
    /// last reached at 00:30 PDT is overdue at 23:30 PST, and the cycle's
    /// slot starts at 00:00 PDT, before the anchor. The fired row at that slot
    /// belongs to this cycle, so no later run on the same cycle may replace it.
    @Test(
        "A 1-day cadence on a 25-hour day does not re-nag its fired row",
        arguments: RepositoryContractBackend.allCases
    )
    func oneDayCadenceOnAFallBackDayDoesNotReNag(backend: RepositoryContractBackend) async throws {
        let allDay = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 23, minute: 59))],
            quietHours: nil,
            timezoneIdentifier: "America/Los_Angeles")
        let fixture = try await PassFixture(backend: backend, window: allDay)
        let contact = Contact(
            id: try contractUUID(7_001),
            systemContactRef: "pass-1",
            displayName: "Pass 1",
            tracked: true,
            cadenceDays: 1,
            lastInteractedAt: EngineFixtures.date("2026-11-01T00:30:00-07:00"),
            createdAt: EngineFixtures.date("2026-01-01T10:00:00-08:00"))
        try await fixture.repositories.contacts.upsert(contact)
        let slotStart = EngineFixtures.date("2026-11-01T00:00:00-07:00")
        var fired = Self.pendingCadenceRow(for: contact, at: slotStart, in: fixture)
        fired.state = .fired
        try await fixture.repositories.reminders.upsert(fired)

        fixture.setNow(EngineFixtures.date("2026-11-01T23:45:00-08:00"))
        try await fixture.pass.runFull()
        #expect(try await fixture.row(fired.id) == fired)
        let writes = await fixture.reminders.writeCount

        try await fixture.pass.runFull()
        #expect(try await fixture.row(fired.id) == fired)

        fixture.setNow(EngineFixtures.date("2026-11-02T00:30:00-08:00"))
        try await fixture.pass.runFull()
        #expect(try await fixture.row(fired.id) == fired)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.reminders.writeCount == writes)
    }

    /// Guard against holding too much. The row fired for an earlier cycle
    /// (S, 06-03 18:00), then the contact was reached at S+1h and the
    /// reschedule that should have followed never ran. When the new cycle
    /// comes due (06-10 19:00 plus 30 minutes) the old fired row must give way
    /// to a pending one for the next slot. Passes on the code before TF-07e
    /// too; it fails if "fired" alone is enough to hold.
    @Test(
        "An old cycle's fired row is replaced once the new cycle is overdue",
        arguments: RepositoryContractBackend.allCases
    )
    func oldCycleFiredRowIsReplacedAfterAMissedReschedule(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, now: "2026-06-10 19:30")
        let contact = try await fixture.addContact(1, cadenceDays: 7, lastInteracted: "2026-06-03 19:00")
        var oldCycle = Self.pendingCadenceRow(for: contact, at: PassFixture.at("2026-06-03 18:00"), in: fixture)
        oldCycle.state = .fired
        try await fixture.repositories.reminders.upsert(oldCycle)

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.id == oldCycle.id)
        #expect(row.state == .pending)
        #expect(row.scheduledFor == PassFixture.at("2026-06-11 18:00"))
    }

    // MARK: - Occasions

    /// The birthday was delivered at 09:00 and the device clock was then set
    /// back to 08:00 the same day. The occurrence is 09:00 again, in the
    /// future, but the row is history: it stays fired and nothing is written.
    @Test(
        "A fired same-day occasion survives the clock moving back before its time",
        arguments: RepositoryContractBackend.allCases
    )
    func firedOccasionSurvivesAClockRollback(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, now: "2026-06-12 08:00", occasions: { contacts in
            contacts.map {
                ContactOccasion(
                    contactId: $0.id, kind: .birthday, monthDay: MonthDay(month: 6, day: 12), label: "Birthday")
            }
        })
        let contact = try await fixture.addContact(1, cadenceDays: 30, lastInteracted: "2026-06-11 10:00")
        try await fixture.pass.runFull()
        let birthdayID = SchedulingPass.reminderID(contactId: contact.id, kind: .birthday)
        let pending = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(pending.scheduledFor == PassFixture.at("2026-06-12 09:00"))
        // The delivery, as the OS reports it, straight into the store.
        #expect(try await fixture.repositories.reminders.transitionState(id: birthdayID, from: .pending, to: .fired))
        var fired = pending
        fired.state = .fired
        #expect(try await fixture.row(birthdayID) == fired)
        let writes = await fixture.reminders.writeCount

        try await fixture.pass.runFull()

        #expect(try await fixture.row(birthdayID) == fired)
        #expect(try await fixture.occasionRow(contact, .birthday) == nil)
        #expect(await fixture.reminders.writeCount == writes)
    }
}
