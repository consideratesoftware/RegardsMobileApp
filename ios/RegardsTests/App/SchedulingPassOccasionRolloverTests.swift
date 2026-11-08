import Foundation
import Testing
@testable import Regards

/// An occasion row across a year rollover and a clock set back (TF-07e, §9
/// "Notification fired", §19 R69). Dates are New York local times
/// (`PassFixture`); occasions fire at the global window's 09:00.
struct SchedulingPassOccasionRolloverTests {

    /// Pin. Records accepted residual R69 (§19, owner ruling 2026-11-06); it
    /// passes on the code before it was written. The row stores no fired
    /// occurrence, so a clock set back across an occasion's rollover re-arms
    /// the occasion once: after a manual rollback the row is pending again and
    /// fires a second time. A fix that stores the fired occurrence turns step 3
    /// (the re-arm) red on purpose; update this test with that change.
    @Test(
        "An occasion that rolled over to next year and then had the clock set back is re-armed once",
        arguments: RepositoryContractBackend.allCases
    )
    func occasionRolloverThenClockRollbackReArmsOnce(backend: RepositoryContractBackend) async throws {
        let id = try contractUUID(7_001)
        let fixture = try await PassFixture(backend: backend, now: "2026-06-12 08:00", occasions: { _ in
            [ContactOccasion(contactId: id, kind: .birthday, monthDay: MonthDay(month: 6, day: 12))]
        })
        let contact = try await fixture.addContact(1, cadenceDays: 30, lastInteracted: "2026-06-11 10:00")
        let birthdayID = SchedulingPass.reminderID(contactId: contact.id, kind: .birthday)
        let thisYear = PassFixture.at("2026-06-12 09:00")
        let nextYear = PassFixture.at("2027-06-12 09:00")

        // 1. The birthday is pending at 09:00, then marked fired straight in the store (as a run at 09:00 would).
        try await fixture.pass.runFull()
        #expect(try await fixture.occasionRow(contact, .birthday)?.scheduledFor == thisYear)
        #expect(try await fixture.repositories.reminders.transitionState(id: birthdayID, from: .pending, to: .fired))

        // 2. The day after, the occasion rolls over to next year.
        fixture.setNow("2026-06-13 10:00")
        try await fixture.pass.runFull()
        let rolledOver = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(rolledOver.scheduledFor == nextYear)

        // 3. The clock is set back before the fired 09:00: the occasion is pending again.
        fixture.setNow("2026-06-12 08:00")
        try await fixture.pass.runFull()
        let rearmed = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(rearmed.scheduledFor == thisYear)
        #expect(rearmed.state == .pending)

        // 4. Once is the limit: the next run on the same clock writes nothing.
        let writes = await fixture.reminders.writeCount
        try await fixture.pass.runFull()
        #expect(try await fixture.occasionRow(contact, .birthday) == rearmed)
        #expect(await fixture.reminders.writeCount == writes)

        // 5. 09:00 arrives again: the row fires a second time and then holds.
        fixture.setNow("2026-06-12 09:01")
        try await fixture.pass.runFull()
        var refired = rearmed
        refired.state = .fired
        #expect(try await fixture.row(birthdayID) == refired)
        #expect(try await fixture.occasionRow(contact, .birthday) == nil)

        // 6. The next rollover schedules next year again.
        fixture.setNow("2026-06-13 10:00")
        try await fixture.pass.runFull()
        #expect(try await fixture.occasionRow(contact, .birthday)?.scheduledFor == nextYear)
    }
}
