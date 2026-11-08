import Foundation
import Testing
@testable import Regards

/// An occasion row across a year rollover and a clock set back (TF-07e, §9
/// "Notification fired", §19 R69). Dates are New York local times
/// (`PassFixture`); occasions fire at the global window's 09:00.
struct SchedulingPassOccasionRolloverTests {

    /// R69 (§19). The row for next year's occurrence stores the fire time of the occurrence it follows
    /// (`firedCycle`), so a clock set back across the rollover can't re-arm the occurrence that already fired.
    /// Before the cycle was stored, step 3 wrote a pending 2026-06-12 09:00 row.
    @Test(
        "An occasion that rolled over to next year is not re-armed when the clock is set back",
        arguments: RepositoryContractBackend.allCases
    )
    func occasionRolloverThenClockRollbackDoesNotReArm(backend: RepositoryContractBackend) async throws {
        let id = try contractUUID(7_001)
        let fixture = try await PassFixture(backend: backend, now: "2026-06-12 08:00", occasions: { _ in
            [ContactOccasion(contactId: id, kind: .birthday, monthDay: MonthDay(month: 6, day: 12))]
        })
        let contact = try await fixture.addContact(1, cadenceDays: 30, lastInteracted: "2026-06-11 10:00")
        let birthdayID = SchedulingPass.reminderID(contactId: contact.id, kind: .birthday)
        let thisYear = PassFixture.at("2026-06-12 09:00")
        let nextYear = PassFixture.at("2027-06-12 09:00")

        // 1. The birthday is pending at 09:00, then marked fired straight in the store
        //    (as a run at 09:00 would).
        try await fixture.pass.runFull()
        #expect(try await fixture.occasionRow(contact, .birthday)?.scheduledFor == thisYear)
        #expect(try await fixture.repositories.reminders.transitionState(id: birthdayID, from: .pending, to: .fired))

        // 2. The day after, the occasion rolls over to next year and the row keeps the fired 09:00.
        fixture.setNow("2026-06-13 10:00")
        try await fixture.pass.runFull()
        let rolledOver = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(rolledOver.scheduledFor == nextYear)
        #expect(rolledOver.firedCycle == thisYear)
        let writes = await fixture.reminders.writeCount

        // 3. The clock is set back before the fired 09:00, moved past it, and forward again: the row stays.
        for clock in ["2026-06-12 08:00", "2026-06-12 09:01", "2026-06-13 10:00"] {
            fixture.setNow(clock)
            try await fixture.pass.runFull()

            #expect(try await fixture.occasionRow(contact, .birthday) == rolledOver, "at \(clock)")
            #expect(try await fixture.row(birthdayID) == rolledOver, "at \(clock)")
            #expect(await fixture.reminders.writeCount == writes, "at \(clock)")
        }
    }

    /// Pin. Records the narrowed R69 (§19): it passes on the code before the cycle was stored and guards
    /// nothing; it turns red on purpose when the residual is fixed. The orphan sweep cancels next year's row
    /// when the contact is untracked, and the snapshot holds no cancelled row, so the carried fire time is lost
    /// with it. After the contact returns and the clock is set back to the fired day, the occasion re-arms once.
    @Test(
        "An occasion whose next-year row was cancelled is re-armed once by a clock set back",
        arguments: RepositoryContractBackend.allCases
    )
    func cancelledNextYearOccasionRowReArmsOnceAfterARollback(backend: RepositoryContractBackend) async throws {
        let id = try contractUUID(7_001)
        let fixture = try await PassFixture(backend: backend, now: "2026-06-12 08:00", occasions: { _ in
            [ContactOccasion(contactId: id, kind: .birthday, monthDay: MonthDay(month: 6, day: 12))]
        })
        let contact = try await fixture.addContact(1, cadenceDays: 30, lastInteracted: "2026-06-11 10:00")
        let birthdayID = SchedulingPass.reminderID(contactId: contact.id, kind: .birthday)
        let thisYear = PassFixture.at("2026-06-12 09:00")
        let nextYear = PassFixture.at("2027-06-12 09:00")

        // 1. The birthday fires on 06-12 and rolls over to next year on 06-13.
        try await fixture.pass.runFull()
        #expect(try await fixture.repositories.reminders.transitionState(id: birthdayID, from: .pending, to: .fired))
        fixture.setNow("2026-06-13 10:00")
        try await fixture.pass.runFull()
        #expect(try await fixture.occasionRow(contact, .birthday)?.firedCycle == thisYear)

        // 2. The contact is untracked on 06-14: the sweep cancels next year's row. Tracked again, the next
        //    run writes a fresh row for next year, with no memory of the fired occurrence.
        fixture.setNow("2026-06-14 10:00")
        var untracked = contact
        untracked.tracked = false
        try await fixture.repositories.contacts.upsert(untracked)
        try await fixture.pass.runFull()
        #expect(try await fixture.occasionRow(contact, .birthday) == nil)
        try await fixture.repositories.contacts.upsert(contact)
        try await fixture.pass.runFull()
        let returned = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(returned.scheduledFor == nextYear)
        #expect(returned.firedCycle == nil)

        // 3. The clock is set back before the fired 09:00: the occasion is pending again, once.
        fixture.setNow("2026-06-12 08:00")
        try await fixture.pass.runFull()
        let rearmed = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(rearmed.scheduledFor == thisYear)
        #expect(rearmed.state == .pending)
        let writes = await fixture.reminders.writeCount
        try await fixture.pass.runFull()
        #expect(try await fixture.occasionRow(contact, .birthday) == rearmed)
        #expect(await fixture.reminders.writeCount == writes)

        // 4. 09:00 arrives again: the row fires a second time and then holds.
        fixture.setNow("2026-06-12 09:01")
        try await fixture.pass.runFull()
        var refired = rearmed
        refired.state = .fired
        #expect(try await fixture.row(birthdayID) == refired)
        #expect(try await fixture.occasionRow(contact, .birthday) == nil)
    }
}
