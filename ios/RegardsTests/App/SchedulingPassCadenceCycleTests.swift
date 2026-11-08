import Foundation
import Testing
@testable import Regards

/// The cadence cycle in rows (TF-07c, §9): what a fired row, a caught-up and
/// a failed caught-up leave behind, and what the next run derives from them.
/// Dates are New York local times (`PassFixture`): the default window opens a
/// slot at 18:00 every day.
struct SchedulingPassCadenceCycleTests {

    /// A fired cadence row by hand. `cycle` is the contact's overdue time, as the pass stores it in `firedCycle`.
    private static func firedRow(
        for contact: Contact, scheduledFor: String, cycle: String? = nil, in fixture: PassFixture
    ) -> ScheduledReminder {
        ScheduledReminder(
            id: fixture.cadenceID(contact),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: PassFixture.at(scheduledFor),
            osNotificationId: "contact-\(contact.id.uuidString)-cadence",
            state: .fired,
            firedCycle: cycle.map(PassFixture.at))
    }

    // MARK: - Fired rows (§9 "Notification fired")

    @Test("A fired row stays fired while the contact is still overdue", arguments: RepositoryContractBackend.allCases)
    func firedRowNotRescheduled(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        // Overdue since 05-08 10:00 (the 05-01 10:00 interaction plus 7 days): the row's cycle.
        let fired = Self.firedRow(for: contact, scheduledFor: "2026-06-09 18:00", cycle: "2026-05-08 10:00", in: fixture)
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
        // Talked this morning, after the 06-09 18:00 row was fired.
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

    /// `recordInteraction` reschedules inside its own lock span, so the next
    /// cycle's row exists the moment the call returns: the new anchor plus
    /// the cadence, resolved into the window, with the old floor gone. No
    /// run is needed, and the run that follows has nothing to write.
    @Test(
        "Caught up and Log other write the next cadence row in the same call",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases, [SchedulingPass.Interaction.caughtUp, .other(.sms)]
    )
    func caughtUpReschedulesInTheSameCall(
        backend: RepositoryContractBackend, interaction: SchedulingPass.Interaction
    ) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1, cadenceDays: 14)
        // The mock backend's seed cast has no rows until a run writes them. This run does,
        // so the last run below has no seed rows left to write.
        try await fixture.pass.runFull()
        #expect(try await fixture.pass.snooze(contactId: contact.id))
        #expect(try await fixture.cadenceRow(contact)?.snoozedUntil == PassFixture.at("2026-06-17 10:00"))

        #expect(try await fixture.pass.recordInteraction(contactId: contact.id, interaction))

        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.state == .pending)
        #expect(row.scheduledFor == PassFixture.at("2026-06-24 18:00"))
        #expect(row.snoozedUntil == nil)
        let writes = await fixture.reminders.writeCount
        try await fixture.pass.runFull()
        #expect(await fixture.reminders.writeCount == writes)
        #expect(try await fixture.cadenceRow(contact) == row)
    }

    /// The reschedule that follows an interaction upserts the same id, so the
    /// final row cannot show that the old one was cleared. The compare-and-set
    /// log can: a fired row moved to `userCaughtUp`.
    @Test(
        "An interaction moves a fired cadence row to userCaughtUp before the reschedule",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases,
        [SchedulingPass.Interaction.caughtUp, .caughtUpFromNotification, .other(.sms)]
    )
    func caughtUpClearsAFiredCadenceRow(
        backend: RepositoryContractBackend, interaction: SchedulingPass.Interaction
    ) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        let fired = Self.firedRow(for: contact, scheduledFor: "2026-06-09 18:00", in: fixture)
        try await fixture.repositories.reminders.upsert(fired)

        #expect(try await fixture.pass.recordInteraction(contactId: contact.id, interaction))

        let cleared = TransitionCall(id: fired.id, from: .fired, to: .userCaughtUp, applied: true)
        #expect(await fixture.reminders.transitionLog.contains(cleared))
        let next = try #require(try await fixture.cadenceRow(contact))
        #expect(next.scheduledFor == PassFixture.at("2026-06-17 18:00"))
        #expect(next.state == .pending)
    }

    /// A failed log puts the snoozed row back as it was, floor included, and
    /// the next run keeps it. Fails if the restore is dropped: the row would
    /// stay `userCaughtUp`, and the run would then write a floorless row at
    /// the overdue slot.
    @Test(
        "A failed Caught up throws, leaves the snoozed row as it was, and the next run keeps its floor",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func failedCaughtUpKeepsSnoozeFloor(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, interactions: StubInteractionRepository.failing())
        let contact = try await fixture.addContact(1)
        #expect(try await fixture.pass.snooze(contactId: contact.id))
        let snoozed = try #require(try await fixture.cadenceRow(contact))
        #expect(snoozed.snoozedUntil == PassFixture.at("2026-06-17 10:00"))
        #expect(snoozed.scheduledFor == PassFixture.at("2026-06-17 18:00"))

        await #expect(throws: RepositoryFakeFailure.self) {
            try await fixture.pass.recordInteraction(contactId: contact.id, .caughtUp)
        }
        #expect(try await fixture.cadenceRow(contact) == snoozed)
        try await fixture.pass.runFull()

        #expect(try await fixture.cadenceRow(contact) == snoozed)
    }

    /// A `userCaughtUp` row can linger: the reschedule after a catch-up failed,
    /// or the contact lost capacity. The restore is for a row this call
    /// cleared, so a later failed log must not turn that lingering row back
    /// into a pending one for a catch-up the user already made. Fails if the
    /// restore runs without `cleared`.
    @Test(
        "A failed log does not turn a lingering caught-up row back into a pending one",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func failedLogDoesNotResurrectALingeringCaughtUpRow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, interactions: StubInteractionRepository.failing())
        let contact = try await fixture.addContact(1, cadenceDays: 14)
        #expect(try await fixture.pass.snooze(contactId: contact.id))
        #expect(try await fixture.repositories.reminders.transitionState(
            id: fixture.cadenceID(contact), from: .pending, to: .userCaughtUp))
        #expect(try await fixture.cadenceRow(contact) == nil)

        await #expect(throws: RepositoryFakeFailure.self) {
            try await fixture.pass.recordInteraction(contactId: contact.id, .caughtUp)
        }

        #expect(try await fixture.cadenceRow(contact) == nil)
    }

    enum LostCover: String, CaseIterable, Sendable {
        case zeroCapacity, untracked
    }

    /// Pin of today's behavior, not a goal. When the contact has no capacity or
    /// is no longer tracked by the time of an in-app catch-up, the interaction
    /// is logged, the snooze is cleared, and no pending row replaces it: the
    /// row stays `userCaughtUp`, which is not pending. For zero capacity the
    /// contact is recorded in `zeroCapacityContactIds`, and once capacity
    /// returns the next run writes the next cycle's row.
    @Test(
        "A catch-up for a contact with no capacity or eligibility logs and leaves no pending row",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases, LostCover.allCases
    )
    func recordInteractionLeavesNoPendingRowWithoutCapacityOrEligibility(
        backend: RepositoryContractBackend, cover: LostCover
    ) async throws {
        let fixture = try await PassFixture(backend: backend)
        var contact = try await fixture.addContact(1, cadenceDays: 14)
        #expect(try await fixture.pass.snooze(contactId: contact.id))
        switch cover {
        case .zeroCapacity:
            // Quiet hours 17:00-20:00 cover the whole 18:00-19:00 range.
            let quiet = TimeRange(start: TimeOfDay(hour: 17), end: TimeOfDay(hour: 20))
            _ = try await fixture.repositories.contacts.updateReminderWindowOverride(
                id: contact.id, window: PassFixture.eveningWindow(quiet: quiet))
        case .untracked:
            contact.tracked = false
            try await fixture.repositories.contacts.upsert(contact)
        }

        #expect(try await fixture.pass.recordInteraction(contactId: contact.id, .caughtUp))

        let logs = try await fixture.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10)
        #expect(logs.count == 1)
        let stored = try #require(try await fixture.repositories.contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == PassFixture.at("2026-06-10 10:00"))
        #expect(try await fixture.cadenceRow(contact) == nil)
        guard cover == .zeroCapacity else { return }
        #expect(await fixture.pass.zeroCapacityContactIds.contains(contact.id))
        _ = try await fixture.repositories.contacts.updateReminderWindowOverride(id: contact.id, window: nil)

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.scheduledFor == PassFixture.at("2026-06-24 18:00"))
        #expect(row.snoozedUntil == nil)
    }

    /// The reschedule is the last step of the span and the interaction has
    /// already landed, so a snapshot that fails to read must not turn the
    /// action into a failure the caller would retry (and log twice). The row
    /// stays `userCaughtUp` until the next run writes the next cycle's.
    @Test(
        "A logged interaction survives a failed reschedule, and the next run writes the next row",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func loggedInteractionSurvivesAFailedReschedule(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1, cadenceDays: 14)
        #expect(try await fixture.pass.snooze(contactId: contact.id))
        await fixture.reminders.setFetchFails(true)

        #expect(try await fixture.pass.recordInteraction(contactId: contact.id, .caughtUp))

        let logs = try await fixture.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10)
        #expect(logs.map(\.source) == [.reminderCaughtUp])
        let stored = try #require(try await fixture.repositories.contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == PassFixture.at("2026-06-10 10:00"))
        #expect(try await fixture.cadenceRow(contact) == nil)
        await fixture.reminders.setFetchFails(false)

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.scheduledFor == PassFixture.at("2026-06-24 18:00"))
        #expect(row.snoozedUntil == nil)
    }

    /// Owner ruling 11: only a notification's Caught up needs a cadence-
    /// eligible contact. The in-app actions work for any active contact, so
    /// an untracked one can still be logged against from Contact Detail.
    /// Fails if the eligibility check leaks into the in-app kinds.
    @Test(
        "In-app actions log for an untracked active contact; the notification kind refuses and logs nothing",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases,
        [SchedulingPass.Interaction.caughtUp, .other(.sms), .caughtUpFromNotification]
    )
    func inAppActionsStayOpenForUntrackedActiveContact(
        backend: RepositoryContractBackend, interaction: SchedulingPass.Interaction
    ) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1, cadenceDays: 14, tracked: false)
        let expectLogged = interaction != .caughtUpFromNotification

        let result = try await fixture.pass.recordInteraction(contactId: contact.id, interaction)

        #expect(result == expectLogged)
        let logs = try await fixture.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10)
        #expect(logs.count == (expectLogged ? 1 : 0))
        let stored = try #require(try await fixture.repositories.contacts.fetch(id: contact.id))
        let expectedAnchor = expectLogged ? PassFixture.at("2026-06-10 10:00") : contact.lastInteractedAt
        #expect(stored.lastInteractedAt == expectedAnchor)
        #expect(try await fixture.cadenceRow(contact) == nil)
    }

    /// Log other records `.manual` against the channel the user picked, for
    /// every channel, and Caught up uses the contact's own preferred one.
    @Test("Log other logs .manual against each channel", .timeLimit(.minutes(1)), arguments: Channel.allCases)
    func recordInteractionLogsEveryChannel(channel: Channel) async throws {
        let fixture = try await PassFixture(backend: .mock)
        let contact = try await fixture.addContact(1)

        #expect(try await fixture.pass.recordInteraction(contactId: contact.id, .other(channel)))

        let logs = try await fixture.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10)
        #expect(logs.count == 1)
        #expect(logs.first?.source == .manual)
        #expect(logs.first?.channel == channel)
    }

    /// Plain no-re-nag with a floor: the snoozed slot has started, the contact
    /// has not talked to the person, and is still overdue. The run marks the
    /// row fired and leaves it, floor included, as it was, and a second run
    /// writes nothing.
    @Test(
        "A snoozed row whose slot has started is marked fired and left alone while the contact is still overdue",
        arguments: RepositoryContractBackend.allCases
    )
    func dueSnoozedRowIsLeftAloneWithoutInteraction(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        #expect(try await fixture.pass.snooze(contactId: contact.id))
        let snoozed = try #require(try await fixture.cadenceRow(contact))
        #expect(snoozed.scheduledFor == PassFixture.at("2026-06-17 18:00"))
        #expect(snoozed.snoozedUntil == PassFixture.at("2026-06-17 10:00"))
        var fired = snoozed
        fired.state = .fired
        fixture.setNow("2026-06-17 18:30")

        try await fixture.pass.runFull()

        #expect(try await fixture.row(snoozed.id) == fired)
        #expect(try await fixture.cadenceRow(contact) == nil)
        let writes = await fixture.reminders.writeCount
        try await fixture.pass.runFull()
        #expect(try await fixture.row(snoozed.id) == fired)
        #expect(await fixture.reminders.writeCount == writes)
    }

    /// Contact Detail asks the pass for the snooze date. Once the snoozed slot
    /// has started the snooze is over, although the row keeps its floor, so the
    /// answer is nil rather than a time in the past.
    @Test(
        "pendingSnoozeDate is nil once the snoozed slot has started",
        arguments: RepositoryContractBackend.allCases
    )
    func pendingSnoozeDateIsNilOnceTheSlotStarts(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1)
        #expect(try await fixture.pass.snooze(contactId: contact.id))
        #expect(try await fixture.pass.pendingSnoozeDate(contactId: contact.id) == PassFixture.at("2026-06-17 18:00"))
        fixture.setNow("2026-06-17 18:30")

        // Before any run the row is still pending with its floor, so only the
        // answer's own check on the slot keeps it from reporting a past time.
        #expect(try await fixture.pass.pendingSnoozeDate(contactId: contact.id) == nil)

        try await fixture.pass.runFull()

        // The row is fired now and keeps its spent floor.
        #expect(try await fixture.row(fixture.cadenceID(contact))?.snoozedUntil == PassFixture.at("2026-06-17 10:00"))
        #expect(try await fixture.pass.pendingSnoozeDate(contactId: contact.id) == nil)
    }

    // MARK: - Pins: a row that left the snapshot never blocks the next one

    /// Pin. A caught-up row (`userCaughtUp`) and a cancelled row are not in
    /// the snapshot, so the no-re-nag guard never sees them, however far the
    /// clock has moved past the old `scheduledFor`. If the snapshot ever
    /// returned them, the guard (`anchor <= old scheduledFor`) would keep a
    /// stale row here and the contact would get no reminder. A caught-up row
    /// only lingers when the reschedule inside `recordInteraction` failed, so
    /// this sets that up.
    @Test(
        "A caught-up row left by a failed reschedule is replaced by a new pending row when overdue again",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpWithTheOldSlotAheadGetsAFreshRowLater(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1, cadenceDays: 7)
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == PassFixture.at("2026-06-10 18:00"))
        await fixture.reminders.setFetchFails(true)
        #expect(try await fixture.pass.recordInteraction(contactId: contact.id, .caughtUp))
        await fixture.reminders.setFetchFails(false)
        #expect(try await fixture.cadenceRow(contact) == nil)
        // Past the old 06-10 18:00 slot and past the new due date, 06-17 10:00.
        fixture.setNow("2026-06-18 10:00")

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.state == .pending)
        #expect(row.scheduledFor == PassFixture.at("2026-06-18 18:00"))
        #expect(row.snoozedUntil == nil)
    }

    @Test(
        "A cancelled cadence row does not block the new row when the cadence is set again",
        arguments: RepositoryContractBackend.allCases
    )
    func cancelledRowDoesNotBlockTheNextOne(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(1, cadenceDays: 7)
        try await fixture.pass.runFull()
        var cleared = contact
        cleared.cadenceDays = nil
        try await fixture.repositories.contacts.upsert(cleared)
        try await fixture.pass.runFull()
        #expect(try await fixture.cadenceRow(contact) == nil)
        try await fixture.repositories.contacts.upsert(contact)
        // Past the cancelled row's 06-10 18:00.
        fixture.setNow("2026-06-11 10:00")

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.cadenceRow(contact))
        #expect(row.state == .pending)
        #expect(row.scheduledFor == PassFixture.at("2026-06-11 18:00"))
    }
}
