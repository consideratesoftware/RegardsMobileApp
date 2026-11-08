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

    /// Every day 00:00-23:59 in Los Angeles: on 2026-11-01, which is 25 hours
    /// long, a 1-day cadence's slot can start before its anchor.
    private static let allDayLosAngeles = ReminderWindow(
        allowedDays: .allDays,
        allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 23, minute: 59))],
        quietHours: nil,
        timezoneIdentifier: "America/Los_Angeles")

    /// A tracked contact with a 1-day cadence; `lastInteractedAt` is ISO 8601.
    private static func addLosAngelesContact(
        to fixture: PassFixture, lastInteractedAt: String
    ) async throws -> Contact {
        let contact = Contact(
            id: try contractUUID(7_001),
            systemContactRef: "pass-1",
            displayName: "Pass 1",
            tracked: true,
            cadenceDays: 1,
            lastInteractedAt: EngineFixtures.date(lastInteractedAt),
            createdAt: EngineFixtures.date("2026-01-01T10:00:00-08:00"))
        try await fixture.repositories.contacts.upsert(contact)
        return contact
    }

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

    /// An overdue contact joins the slot in progress: the row's slot has
    /// already started, so it is written fired, never pending, and the next
    /// run has nothing to mark.
    @Test(
        "A row written into the slot in progress is fired, and the next run writes nothing",
        arguments: RepositoryContractBackend.allCases, ["18:30", "18:00"]
    )
    func joiningTheSlotInProgressWritesAFiredRow(backend: RepositoryContractBackend, time: String) async throws {
        let fixture = try await PassFixture(backend: backend, now: "2026-06-10 \(time)")
        let contact = try await fixture.addContact(1)

        try await fixture.pass.runFull()

        let joined = try #require(try await fixture.row(fixture.cadenceID(contact)))
        #expect(joined.scheduledFor == PassFixture.at("2026-06-10 18:00"))
        #expect(joined.state == .fired)
        #expect(try await fixture.cadenceRow(contact) == nil)
        let writes = await fixture.reminders.writeCount
        try await fixture.pass.runFull()
        #expect(try await fixture.row(joined.id) == joined)
        #expect(await fixture.reminders.writeCount == writes)
    }

    // MARK: - Clock rollback

    /// The device clock is set back 1 hour before the fired row's slot. The
    /// row was delivered, so a rollback never re-arms it: the contact's
    /// overdue time (06-10 17:30) is still ahead of `now` (17:00), yet the
    /// fired row at 18:00 is the slot holding it.
    @Test(
        "A fired cadence row survives the clock being set back before its slot",
        arguments: RepositoryContractBackend.allCases
    )
    func firedCadenceRowSurvivesAClockRollback(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, now: "2026-06-10 18:10")
        let contact = try await fixture.addContact(1, cadenceDays: 7, lastInteracted: "2026-06-03 17:30")
        var fired = Self.pendingCadenceRow(for: contact, at: PassFixture.at("2026-06-10 18:00"), in: fixture)
        fired.state = .fired
        try await fixture.repositories.reminders.upsert(fired)
        // Settles the mock backend's seed cast; the fired row is held.
        try await fixture.pass.runFull()
        #expect(try await fixture.row(fired.id) == fired)
        fixture.setNow("2026-06-10 17:00")
        let writes = await fixture.reminders.writeCount

        try await fixture.pass.runFull()

        #expect(try await fixture.row(fired.id) == fired)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.reminders.writeCount == writes)
    }

    /// A contact who becomes overdue at 18:30 joins the 18:00 slot already in
    /// progress at 18:45, so the row is written fired. The clock then moves
    /// back to 18:15, before the contact's overdue time. The rollback must
    /// not turn that delivered row into a pending one for the next day.
    @Test(
        "A cadence row written into the slot in progress survives the clock being set back before its due time",
        arguments: RepositoryContractBackend.allCases
    )
    func joinedCadenceRowSurvivesAClockRollbackBeforeItsDueTime(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, now: "2026-06-10 18:45")
        let contact = try await fixture.addContact(1, cadenceDays: 7, lastInteracted: "2026-06-03 18:30")
        try await fixture.pass.runFull()
        let joined = try #require(try await fixture.row(fixture.cadenceID(contact)))
        #expect(joined.scheduledFor == PassFixture.at("2026-06-10 18:00"))
        #expect(joined.state == .fired)
        let writes = await fixture.reminders.writeCount
        fixture.setNow("2026-06-10 18:15")

        try await fixture.pass.runFull()

        #expect(try await fixture.row(joined.id) == joined)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.reminders.writeCount == writes)
    }

    /// Records R68, an accepted residual (§19 R68, owner ruling 2026-11-04).
    /// The row stores no fired cycle, so after a window edit moves the slot to 18:30
    /// and the clock is set back to 17:00, the pass derives the delivered
    /// row as pending again; it fires a second time once 18:30 arrives, then
    /// holds. A future fix that stores the fired cycle on the row should turn
    /// step 3 (the re-arm) red on purpose; update this test with that change.
    @Test(
        "A window edit then a clock rollback re-arms a fired row once",
        arguments: RepositoryContractBackend.allCases
    )
    func windowEditThenClockRollbackReArmsOnce(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, now: "2026-06-10 18:10")
        let contact = try await fixture.addContact(1, cadenceDays: 7, lastInteracted: "2026-06-03 17:30")
        var fired = Self.pendingCadenceRow(for: contact, at: PassFixture.at("2026-06-10 18:00"), in: fixture)
        fired.state = .fired
        try await fixture.repositories.reminders.upsert(fired)
        // Settles the mock backend's seed cast; the fired row is held.
        try await fixture.pass.runFull()
        #expect(try await fixture.row(fired.id) == fired)

        // The window now opens at 18:30. The 18:00 row is still held.
        let range = TimeRange(start: TimeOfDay(hour: 18, minute: 30), end: TimeOfDay(hour: 19))
        try await fixture.repositories.window.saveGlobal(ReminderWindow(
            allowedDays: .allDays, allowedTimeRanges: [range], quietHours: nil, timezoneIdentifier: PassFixture.zone))
        try await fixture.pass.runFull()
        #expect(try await fixture.row(fired.id) == fired)

        // Rolled back before the new slot: the row is pending for 18:30.
        fixture.setNow("2026-06-10 17:00")
        try await fixture.pass.runFull()
        let rearmed = try #require(try await fixture.cadenceRow(contact))
        #expect(rearmed.scheduledFor == PassFixture.at("2026-06-10 18:30"))

        // The new slot arrives: the row fires once.
        fixture.setNow("2026-06-10 18:31")
        try await fixture.pass.runFull()
        let refired = try #require(try await fixture.row(fired.id))
        #expect(refired.scheduledFor == PassFixture.at("2026-06-10 18:30"))
        #expect(refired.state == .fired)
        #expect(try await fixture.cadenceRow(contact) == nil)
        let writes = await fixture.reminders.writeCount

        try await fixture.pass.runFull()

        #expect(try await fixture.row(fired.id) == refired)
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
        let joined = try #require(try await fixture.row(fixture.cadenceID(contact)))
        #expect(joined.scheduledFor == slotStart, "the overdue contact joined the slot")
        #expect(joined.state == .fired)
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
        let fixture = try await PassFixture(backend: backend, window: Self.allDayLosAngeles)
        let contact = try await Self.addLosAngelesContact(
            to: fixture, lastInteractedAt: "2026-11-01T00:30:00-07:00")
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
    /// to a pending one for the next slot. The hold must also check that the
    /// row belongs to the current cycle: this fails if "fired" alone holds.
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

    // MARK: - Catch-up clears a fired row (recordInteraction)

    /// The user was caught up at 00:10 PDT on the 25-hour day, but the
    /// reschedule that follows failed (fetch throws once), so no new row was
    /// written. The fired row at 00:00 PDT is the old cycle's, yet it starts
    /// before the new anchor's cycle ends, and the no-re-nag hold would keep it
    /// at 23:15 PST, when the contact is overdue again. The catch-up clears the
    /// fired row, so the hold never sees it and the run writes the new row.
    @Test(
        "A catch-up whose reschedule failed on a 25-hour day still gets its next reminder",
        arguments: RepositoryContractBackend.allCases
    )
    func failedRescheduleAfterCatchUpOnAFallBackDayStillNotifies(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, window: Self.allDayLosAngeles)
        let contact = try await Self.addLosAngelesContact(
            to: fixture, lastInteractedAt: "2026-10-30T12:00:00-07:00")
        let slotStart = EngineFixtures.date("2026-11-01T00:00:00-07:00")
        var fired = Self.pendingCadenceRow(for: contact, at: slotStart, in: fixture)
        fired.state = .fired
        try await fixture.repositories.reminders.upsert(fired)
        fixture.setNow(EngineFixtures.date("2026-11-01T00:05:00-07:00"))
        // Settles the mock backend's seed cast; the fired row is held.
        try await fixture.pass.runFull()
        #expect(try await fixture.row(fired.id) == fired)
        fixture.setNow(EngineFixtures.date("2026-11-01T00:10:00-07:00"))
        await fixture.reminders.setFetchFails(true)

        #expect(try await fixture.pass.recordInteraction(contactId: contact.id, .caughtUp))

        await fixture.reminders.setFetchFails(false)
        let stored = try #require(try await fixture.repositories.contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == fixture.clock.now())
        #expect(try await fixture.row(fired.id) == nil, "the fired row was cleared and nothing replaced it")
        let writes = await fixture.reminders.writeCount

        // Overdue again: 00:10 PDT plus one day is 23:10 PST.
        fixture.setNow(EngineFixtures.date("2026-11-01T23:15:00-08:00"))
        try await fixture.pass.runFull()

        let next = try #require(try await fixture.row(fired.id))
        #expect(next.scheduledFor == slotStart)
        #expect(next.state == .fired)
        #expect(await fixture.reminders.writeCount == writes + 1)
    }

    /// The log write fails after the catch-up cleared a fired row. The row goes
    /// back to fired, not pending, so the failed action neither re-arms a
    /// delivered notification nor loses the history. The error is rethrown.
    @Test(
        "A failed log puts a cleared fired row back as fired and rethrows",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func failedLogRestoresAFiredRow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, interactions: StubInteractionRepository.failing())
        let contact = try await fixture.addContact(1)
        var fired = Self.pendingCadenceRow(for: contact, at: PassFixture.at("2026-06-09 18:00"), in: fixture)
        fired.state = .fired
        try await fixture.repositories.reminders.upsert(fired)

        await #expect(throws: RepositoryFakeFailure.self) {
            try await fixture.pass.recordInteraction(contactId: contact.id, .caughtUp)
        }

        #expect(try await fixture.row(fired.id) == fired)
        let clearing = TransitionCall(id: fired.id, from: .fired, to: .userCaughtUp, applied: true)
        let restoring = TransitionCall(id: fired.id, from: .userCaughtUp, to: .fired, applied: true)
        #expect(await fixture.reminders.transitionLog.filter { $0.applied } == [clearing, restoring])
    }

    /// The reschedule that follows a catch-up upserts the same id, so the
    /// final row cannot show that the old one was cleared. The compare-and-set
    /// log can: a fired row moved to `userCaughtUp`.
    @Test(
        "Caught up moves a fired cadence row to userCaughtUp before the reschedule",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpClearsAFiredCadenceRow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        var fired = Self.pendingCadenceRow(for: contact, at: PassFixture.at("2026-06-09 18:00"), in: fixture)
        fired.state = .fired
        try await fixture.repositories.reminders.upsert(fired)

        #expect(try await fixture.pass.recordInteraction(contactId: contact.id, .caughtUp))

        let cleared = TransitionCall(id: fired.id, from: .fired, to: .userCaughtUp, applied: true)
        #expect(await fixture.reminders.transitionLog.contains(cleared))
        let next = try #require(try await fixture.cadenceRow(contact))
        #expect(next.scheduledFor == PassFixture.at("2026-06-17 18:00"))
        #expect(next.state == .pending)
    }
}
