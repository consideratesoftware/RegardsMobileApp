import Foundation
import Testing
@testable import Regards

/// A fired row keeps its cycle (`ScheduledReminder.firedCycle`, §7 v4, §9
/// "Notification fired"), so a clock set back cannot re-arm it. Split from
/// `SchedulingPassFiredRowTests`, which sits at SwiftLint's type-length limit.
/// Dates are New York local times (`PassFixture`); the default window opens a
/// slot at 18:00 every day.
extension SchedulingPassFiredRowTests {

    // MARK: - Window edit then clock rollback (R68)

    /// The 2 probes of R68. Each lets the pass write a fired row for a contact that becomes overdue inside the
    /// slot in progress, edits the global window so the contact's slot moves, then runs on the clocks in order.
    /// Before the cycle was stored, each rollback derived the row as pending again.
    enum WindowEditProbe: String, CaseIterable, Sendable, CustomTestStringConvertible {
        /// Overdue 06-10 17:30, joins the 18:00 slot at 18:10. The window moves to 18:30-19:00 and the clock is
        /// set back to 17:00, before the overdue time. The old pass re-armed a pending row at 06-10 18:30.
        case newSlotLaterTheSameDay
        /// Overdue 06-10 18:25, joins the 18:00 slot at 18:30. The window moves to 18:15-19:00 and the clock is
        /// set back to 18:20, before the overdue time. The old pass re-armed a pending row at 06-11 18:15.
        case newSlotTheNextDay

        var testDescription: String { rawValue }

        var lastInteracted: String {
            switch self {
            case .newSlotLaterTheSameDay: "2026-06-03 17:30"
            case .newSlotTheNextDay: "2026-06-03 18:25"
            }
        }

        var overdueAt: String {
            switch self {
            case .newSlotLaterTheSameDay: "2026-06-10 17:30"
            case .newSlotTheNextDay: "2026-06-10 18:25"
            }
        }

        var newRange: TimeRange {
            switch self {
            case .newSlotLaterTheSameDay: TimeRange(start: TimeOfDay(hour: 18, minute: 30), end: TimeOfDay(hour: 19))
            case .newSlotTheNextDay: TimeRange(start: TimeOfDay(hour: 18, minute: 15), end: TimeOfDay(hour: 19))
            }
        }

        /// The clock at the first run, which writes the fired row, then the clocks the rest of the runs use.
        var clocks: [String] {
            switch self {
            case .newSlotLaterTheSameDay: ["2026-06-10 18:10", "2026-06-10 17:00", "2026-06-10 18:31"]
            case .newSlotTheNextDay: ["2026-06-10 18:30", "2026-06-10 18:20"]
            }
        }
    }

    /// The row's stored cycle is the contact's overdue time. A window edit moves where the cycle's slot would
    /// fall, but the hold reads no window, so no run after the edit, set back or not, rewrites the row.
    /// R68 is closed by this test; it fails on the pass before the cycle was stored.
    @Test(
        "A window edit then a clock rollback does not re-arm a fired cadence row",
        arguments: RepositoryContractBackend.allCases, WindowEditProbe.allCases
    )
    func windowEditThenClockRollbackDoesNotReArm(
        backend: RepositoryContractBackend, probe: WindowEditProbe
    ) async throws {
        let fixture = try await PassFixture(backend: backend, now: probe.clocks[0])
        let contact = try await fixture.addContact(1, cadenceDays: 7, lastInteracted: probe.lastInteracted)
        try await fixture.pass.runFull()
        let fired = try #require(try await fixture.row(fixture.cadenceID(contact)))
        #expect(fired.state == .fired)
        #expect(fired.scheduledFor == PassFixture.at("2026-06-10 18:00"), "joined the slot in progress")
        #expect(fired.firedCycle == PassFixture.at(probe.overdueAt))

        try await fixture.repositories.window.saveGlobal(ReminderWindow(
            allowedDays: .allDays, allowedTimeRanges: [probe.newRange], quietHours: nil,
            timezoneIdentifier: PassFixture.zone))
        // The edit also moves the mock backend's seed cast, so this run's writes are not counted.
        try await fixture.pass.runFull()
        #expect(try await fixture.row(fired.id) == fired, "at \(probe.clocks[0])")
        #expect(try await fixture.cadenceRow(contact) == nil, "at \(probe.clocks[0])")
        let writes = await fixture.reminders.writeCount

        for clock in probe.clocks.dropFirst() {
            fixture.setNow(clock)
            try await fixture.pass.runFull()

            #expect(try await fixture.row(fired.id) == fired, "at \(clock)")
            #expect(try await fixture.cadenceRow(contact) == nil, "at \(clock)")
            #expect(await fixture.reminders.writeCount == writes, "at \(clock)")
        }
    }
}
