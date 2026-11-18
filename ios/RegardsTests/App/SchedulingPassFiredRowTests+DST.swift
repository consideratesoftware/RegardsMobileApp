import Foundation
import Testing
@testable import Regards

/// A fired cadence row across a spring-forward day (§9 "Notification fired", §9a). Split from
/// `SchedulingPassFiredRowTests`, which sits at SwiftLint's type-length limit. Each day has a gap that
/// swallows the start of the window range, so the slot starts at the gap's end, and the cycle stored on
/// the row is `anchor + cadence * 86_400` in elapsed time, not calendar days.
extension SchedulingPassFiredRowTests {

    /// A spring-forward day whose gap contains the start of the contact's window range.
    enum SpringForwardDay: CaseIterable, Sendable, CustomTestStringConvertible {
        /// America/Los_Angeles 2026-03-08: 02:00 PST jumps to 03:00 PDT. Range [02:30, 05:00) starts at 03:00.
        case losAngeles
        /// Australia/Lord_Howe 2026-10-04: 02:00 +10:30 jumps to 02:30 +11:00. Range [02:00, 04:00) starts at 02:30.
        case lordHowe

        var testDescription: String {
            switch self {
            case .losAngeles: "America/Los_Angeles 2026-03-08"
            case .lordHowe: "Australia/Lord_Howe 2026-10-04"
            }
        }

        var zone: String {
            switch self {
            case .losAngeles: "America/Los_Angeles"
            case .lordHowe: "Australia/Lord_Howe"
            }
        }

        var range: TimeRange {
            switch self {
            case .losAngeles: TimeRange(start: TimeOfDay(hour: 2, minute: 30), end: TimeOfDay(hour: 5))
            case .lordHowe: TimeRange(start: TimeOfDay(hour: 2), end: TimeOfDay(hour: 4))
            }
        }

        /// 7 days before the overdue time.
        var anchor: String {
            switch self {
            case .losAngeles: "2026-03-01T01:30:00-08:00"
            case .lordHowe: "2026-09-27T01:00:00+10:30"
            }
        }

        /// The 5 clocks, in order: before the slot, inside it, rolled back before the overdue time,
        /// the next day inside its slot, the next day before its slot.
        var clocks: [String] {
            switch self {
            case .losAngeles:
                ["2026-03-08T01:45:00-08:00", "2026-03-08T03:10:00-07:00", "2026-03-08T01:00:00-08:00",
                 "2026-03-09T03:10:00-07:00", "2026-03-09T02:00:00-07:00"]
            case .lordHowe:
                ["2026-10-04T01:15:00+10:30", "2026-10-04T02:40:00+11:00", "2026-10-04T00:45:00+10:30",
                 "2026-10-05T02:10:00+11:00", "2026-10-05T01:15:00+11:00"]
            }
        }

        /// The slot start on the spring-forward day: the gap's end, not the nonexistent range start.
        var slot: String {
            switch self {
            case .losAngeles: "2026-03-08T03:00:00-07:00"
            case .lordHowe: "2026-10-04T02:30:00+11:00"
            }
        }

        /// The cycle a 7-day cadence stores: the anchor plus 7 elapsed days.
        var cycle: String {
            switch self {
            case .losAngeles: "2026-03-08T01:30:00-08:00"
            case .lordHowe: "2026-10-04T01:00:00+10:30"
            }
        }

        /// The cycle an 8-day cadence stamps: the anchor plus 8 elapsed days, an hour (or half-hour)
        /// off the same wall-clock time because a day in between is short.
        var stampedCycle: String {
            switch self {
            case .losAngeles: "2026-03-09T02:30:00-07:00"
            case .lordHowe: "2026-10-05T01:30:00+11:00"
            }
        }
    }

    /// The row written before its slot is pending at the gap's end and carries the 7-day cycle. Once it is
    /// marked fired it holds: a clock set back before the overdue time derives nothing and writes nothing. A
    /// longer cadence that is overdue the next day stamps its cycle on the same fired row with 1 write, and
    /// the clocks around it write nothing. The cycle is elapsed time (`cadenceDays * 86_400`, §9): a calendar
    /// day count would stamp an earlier wall-clock cycle on the spring-forward day.
    ///
    /// Pin. The `anchor <= existing.scheduledFor` clause of the stamp: no mutation of it fails this test.
    @Test(
        "A fired cadence row holds and stamps its cycle in elapsed time on a spring-forward day",
        arguments: RepositoryContractBackend.allCases, SpringForwardDay.allCases
    )
    func firedCycleHoldsAndStampsOnASpringForwardDay(
        backend: RepositoryContractBackend, day: SpringForwardDay
    ) async throws {
        let fixture = try await PassFixture(backend: backend, window: ReminderWindow(
            allowedDays: .allDays, allowedTimeRanges: [day.range], quietHours: nil, timezoneIdentifier: day.zone))
        var contact = Contact(
            id: try contractUUID(7_001),
            systemContactRef: "pass-1",
            displayName: "Pass 1",
            tracked: true,
            cadenceDays: 7,
            lastInteractedAt: EngineFixtures.date(day.anchor),
            createdAt: EngineFixtures.date("2026-01-01T10:00:00-08:00"))
        try await fixture.repositories.contacts.upsert(contact)
        let id = fixture.cadenceID(contact)
        let clocks = day.clocks.map { EngineFixtures.date($0) }

        // 1. Before the slot: pending at the gap's end, with the 7-day cycle.
        fixture.setNow(clocks[0])
        try await fixture.pass.runFull()
        let pending = try #require(try await fixture.row(id))
        #expect(pending.state == .pending)
        #expect(pending.scheduledFor == EngineFixtures.date(day.slot))
        #expect(pending.firedCycle == EngineFixtures.date(day.cycle))

        // 2. Inside the slot: the same row, marked fired.
        fixture.setNow(clocks[1])
        try await fixture.pass.runFull()
        var fired = pending
        fired.state = .fired
        #expect(try await fixture.row(id) == fired)
        let writes = await fixture.reminders.writeCount

        // 3. Rolled back before the overdue time: the row holds and no pending row appears.
        fixture.setNow(clocks[2])
        try await fixture.pass.runFull()
        #expect(try await fixture.row(id) == fired)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.reminders.writeCount == writes)

        // 4. The next day, a longer cadence is overdue inside its slot: the same row gets the elapsed-time
        //    cycle, with 1 write. The first run absorbs the mock seed cast's writes.
        fixture.setNow(clocks[3])
        try await fixture.pass.runFull()
        let absorbed = await fixture.reminders.writeCount
        contact.cadenceDays = 8
        try await fixture.repositories.contacts.upsert(contact)
        try await fixture.pass.runFull()
        var stamped = fired
        stamped.firedCycle = EngineFixtures.date(day.stampedCycle)
        #expect(try await fixture.row(id) == stamped)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.reminders.writeCount == absorbed + 1)

        // 5. The next day before its slot: nothing changes.
        fixture.setNow(clocks[4])
        try await fixture.pass.runFull()
        #expect(try await fixture.row(id) == stamped)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.reminders.writeCount == absorbed + 1)
    }
}
