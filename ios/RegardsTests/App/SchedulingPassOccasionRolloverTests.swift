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

    /// Owner answer 1, 2026-11-09 (§9 "Notification fired"). A clock that ran ahead past an occasion and was
    /// then corrected notifies at most once: the run on the fast clock marked the row fired and wrote next
    /// year's row with the fire time, so no later clock re-arms the occasion.
    @Test(
        "An occasion passed by a fast clock is not re-armed when the clock is corrected",
        arguments: RepositoryContractBackend.allCases
    )
    func fastClockPastAnOccasionThenCorrectedDoesNotReArm(backend: RepositoryContractBackend) async throws {
        let id = try contractUUID(7_001)
        let fixture = try await PassFixture(backend: backend, now: "2026-06-10 10:00", occasions: { _ in
            [ContactOccasion(contactId: id, kind: .birthday, monthDay: MonthDay(month: 6, day: 12))]
        })
        let contact = try await fixture.addContact(1, cadenceDays: 30, lastInteracted: "2026-06-09 10:00")
        let birthdayID = SchedulingPass.reminderID(contactId: contact.id, kind: .birthday)

        // 1. On the true clock the birthday is pending for 06-12 09:00, with no cycle.
        try await fixture.pass.runFull()
        let pending = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(pending.scheduledFor == PassFixture.at("2026-06-12 09:00"))
        #expect(pending.firedCycle == nil)

        // 2. The clock runs ahead to 06-13. The run marks the row fired and writes next year's row.
        fixture.setNow("2026-06-13 10:00")
        try await fixture.pass.runFull()
        let rolledOver = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(rolledOver.scheduledFor == PassFixture.at("2027-06-12 09:00"))
        #expect(rolledOver.firedCycle == PassFixture.at("2026-06-12 09:00"))

        // 3. The clock is corrected to before the occasion, passes it, and moves ahead again: the row stays.
        let writes = await fixture.reminders.writeCount
        for clock in ["2026-06-10 10:00", "2026-06-12 08:00", "2026-06-12 09:01", "2026-06-13 10:00"] {
            fixture.setNow(clock)
            try await fixture.pass.runFull()

            #expect(try await fixture.occasionRow(contact, .birthday) == rolledOver, "at \(clock)")
            #expect(try await fixture.row(birthdayID) == rolledOver, "at \(clock)")
            #expect(await fixture.reminders.writeCount == writes, "at \(clock)")
        }
    }

    /// Pin. Records the narrowed R69 (§19): TF-07f fixes it. It guards nothing, and it turns red on purpose
    /// when the residual is fixed. The orphan sweep cancels next year's row
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

    // MARK: - The February boundary in 2028 (a leap year) and 2029

    /// A birthday on 02-28 or on 02-29 that fired in the leap year 2028 rolls over to 2029, where 02-29 falls
    /// back to 02-28. The row stores the fired 09:00 as its cycle, so clocks around the boundary can't re-arm it
    /// (§9 "Notification fired"). At the fire day's 23:30 the fire-now occurrence is later than 09:00 on the same
    /// day, and the hold compares days in the contact's zone, so the run writes nothing.
    ///
    /// Pin. The "dayBefore 10:00" clock: a clock set back a whole day is held by the same day comparison, and no
    /// mutation of the zone or the comparison named in this round fails at that clock alone.
    @Test(
        "A leap-year birthday that fired is not re-armed by clocks around the February boundary",
        arguments: RepositoryContractBackend.allCases, LeapBirthday.allCases
    )
    func leapYearOccasionHoldsAcrossTheFebruaryBoundary(
        backend: RepositoryContractBackend, birthday: LeapBirthday
    ) async throws {
        let id = try contractUUID(7_001)
        let fixture = try await PassFixture(backend: backend, now: "2028-02-20 12:00", occasions: { _ in
            [ContactOccasion(contactId: id, kind: .birthday, monthDay: birthday.monthDay)]
        })
        let contact = try await fixture.addContact(1, cadenceDays: 30, lastInteracted: "2028-02-20 10:00")
        let birthdayID = SchedulingPass.reminderID(contactId: contact.id, kind: .birthday)
        let fireDay = birthday.fireDay

        // 1. The day of the birthday, before 09:00: pending at 09:00.
        fixture.setNow("\(fireDay) 08:00")
        try await fixture.pass.runFull()
        #expect(try await fixture.occasionRow(contact, .birthday)?.scheduledFor == PassFixture.at("\(fireDay) 09:00"))

        // 2. After 09:00 the run marks it fired.
        fixture.setNow("\(fireDay) 09:30")
        try await fixture.pass.runFull()
        let fired = try #require(try await fixture.row(birthdayID))
        #expect(fired.state == .fired)
        #expect(fired.scheduledFor == PassFixture.at("\(fireDay) 09:00"))

        // 3. After midnight the occasion rolls over to 2029-02-28 and the row keeps the fired 09:00.
        fixture.setNow("\(birthday.nextDay) 00:30")
        try await fixture.pass.runFull()
        let rolledOver = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(rolledOver.scheduledFor == PassFixture.at("2029-02-28 09:00"))
        #expect(rolledOver.firedCycle == PassFixture.at("\(fireDay) 09:00"))
        #expect(rolledOver.occasionDate == birthday.rolledOverDate)
        let writes = await fixture.reminders.writeCount

        // 4. The late evening of the fire day, the day before, and after midnight again: the row stays.
        for clock in ["\(fireDay) 23:30", "\(birthday.dayBefore) 10:00", "\(birthday.nextDay) 00:30"] {
            fixture.setNow(clock)
            try await fixture.pass.runFull()

            #expect(try await fixture.row(birthdayID) == rolledOver, "at \(clock)")
            #expect(try await fixture.occasionRow(contact, .birthday) == rolledOver, "at \(clock)")
            #expect(await fixture.reminders.writeCount == writes, "at \(clock)")
        }
    }

    /// The 2 birthdays around the leap day, with the days the test steps through (all in 2028).
    enum LeapBirthday: CaseIterable, Sendable, CustomTestStringConvertible {
        case feb28
        case feb29

        var testDescription: String { monthDay.isoString }

        var monthDay: MonthDay {
            switch self {
            case .feb28: MonthDay(month: 2, day: 28)
            case .feb29: MonthDay(month: 2, day: 29)
            }
        }

        var fireDay: String { self == .feb28 ? "2028-02-28" : "2028-02-29" }
        var nextDay: String { self == .feb28 ? "2028-02-29" : "2028-03-01" }
        var dayBefore: String { self == .feb28 ? "2028-02-27" : "2028-02-28" }
        /// The occasion date a 2029 row stores: 02-29 stays on the row even though 2029 has no leap day.
        var rolledOverDate: String { self == .feb28 ? "02-28" : "02-29" }
    }

    /// A 02-29 birthday falls back to 02-28 only in a common year (§9 annual recurrence, §2). After it fired on
    /// 2027-02-28, the next occurrence is the leap day 2028-02-29, not 02-28.
    @Test(
        "A Feb 29 birthday fires on Feb 28 in a common year, then on the leap day",
        arguments: RepositoryContractBackend.allCases
    )
    func feb29BirthdayFiresOnFeb28ThenOnTheLeapDay(backend: RepositoryContractBackend) async throws {
        let id = try contractUUID(7_001)
        let fixture = try await PassFixture(backend: backend, now: "2027-02-20 12:00", occasions: { _ in
            [ContactOccasion(contactId: id, kind: .birthday, monthDay: MonthDay(month: 2, day: 29))]
        })
        let contact = try await fixture.addContact(1, cadenceDays: nil, lastInteracted: nil)
        let birthdayID = SchedulingPass.reminderID(contactId: contact.id, kind: .birthday)

        // 1. 2027 has no leap day: the birthday is pending on 02-28 at 09:00 and keeps its 02-29 date.
        fixture.setNow("2027-02-28 08:00")
        try await fixture.pass.runFull()
        let pending = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(pending.scheduledFor == PassFixture.at("2027-02-28 09:00"))
        #expect(pending.occasionDate == "02-29")

        // 2. After 09:00 it is fired.
        fixture.setNow("2027-02-28 09:30")
        try await fixture.pass.runFull()
        #expect(try await fixture.row(birthdayID)?.state == .fired)

        // 3. On 03-01 the next occurrence is the leap day 2028-02-29, with the fired 09:00 as its cycle.
        fixture.setNow("2027-03-01 00:30")
        try await fixture.pass.runFull()
        let rolledOver = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(rolledOver.scheduledFor == PassFixture.at("2028-02-29 09:00"))
        #expect(rolledOver.firedCycle == PassFixture.at("2027-02-28 09:00"))

        // 4. The eve of the leap day: the row is unchanged and still pending. The mock seed cast moves the
        //    write count here, so the row is the assertion.
        fixture.setNow("2028-02-28 23:30")
        try await fixture.pass.runFull()
        #expect(try await fixture.occasionRow(contact, .birthday) == rolledOver)

        // 5. After 09:00 on the leap day it is fired at 09:00.
        fixture.setNow("2028-02-29 09:30")
        try await fixture.pass.runFull()
        let fired = try #require(try await fixture.row(birthdayID))
        #expect(fired.state == .fired)
        #expect(fired.scheduledFor == PassFixture.at("2028-02-29 09:00"))
    }
}
