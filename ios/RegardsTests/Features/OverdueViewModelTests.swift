import Foundation
import Testing
@testable import Regards

/// Locks in the DST-correct day math on `OverdueViewModel.makeOverdueRow`.
/// The VM injects `Calendar` so we can pin a fixed timezone for the test —
/// production code defaults to `.current` (user-local), which drifts from
/// `window.timeZone` by a calendar day across DST transitions and for
/// travelers.
///
/// The canonical divergence between seconds-based math and calendar-based
/// math is **spring-forward**: wall-clock advances by one day but real
/// elapsed time is 23 hours, so `Int(seconds / 86_400)` undercounts by one
/// day. Fall-back *gains* an hour, so seconds-based rounding still lands on
/// the right day in normal cases — fixtures anchored on fall-back don't
/// actually exercise the bug the Calendar fix prevents.
///
/// Both directions kept as regression tests because devs instinctively
/// reach for `seconds / 86_400`; if someone reverts, spring-forward is the
/// one that trips.
@MainActor
struct OverdueViewModelTests {

    static func makeCalendar(tz: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz) ?? .current
        return calendar
    }

    static func date(_ iso: String, tz: String) -> Date {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = TimeZone(identifier: tz) ?? .current
        return df.date(from: iso)!
    }

    static func makeContact(lastInteractedAt: Date, cadenceDays: Int) -> Contact {
        Contact(
            systemContactRef: "sys-test",
            displayName: "Alex Chen",
            tracked: true,
            cadenceDays: cadenceDays,
            priorityTier: .close,
            preferredChannel: .signal,
            preferredChannelValue: "+14155550198",
            lastInteractedAt: lastInteractedAt
        )
    }

    // MARK: - Spring-forward (America/Los_Angeles, 2026-03-08)

    /// Wall-clock 09:00 Sat Mar 7 → 09:00 Sun Mar 8 LA = **one calendar
    /// day** but only 23 real hours (02:00 → 03:00 springs forward). Seconds-
    /// based math: `82800 / 86_400 = 0` → **undercounts by a day**.
    /// Calendar-based math correctly returns 1. If anyone reverts
    /// `makeOverdueRow` to `Int(seconds / 86_400)`, this test fails.
    @Test("Spring-forward boundary: calendar day count is 1, not 0")
    func springForwardBoundary() {
        let la = "America/Los_Angeles"
        let calendar = Self.makeCalendar(tz: la)
        // Cadence 1 day: due Sat Mar 7 09:00, the instant the day count runs from.
        let last = Self.date("2026-03-06 09:00", tz: la)
        let now  = Self.date("2026-03-08 09:00", tz: la)  // 23h elapsed, 1 wall day
        let contact = Self.makeContact(lastInteractedAt: last, cadenceDays: 1)

        let row = OverdueViewModel.makeOverdueRow(for: contact, now: now, calendar: calendar)
        #expect(row?.overdueDays == 1)
    }

    /// Spring-forward across multiple days — exact 14 calendar days between
    /// Feb 23 09:00 PST and Mar 9 09:00 PDT, despite only 14·24 − 1 = 335
    /// real hours. Seconds math: `1206000 / 86_400 = 13.96 → 13` (one short).
    /// Calendar: 14.
    @Test("Spring-forward spans multi-day window: calendar returns the full count")
    func springForwardMultiDay() {
        let la = "America/Los_Angeles"
        let calendar = Self.makeCalendar(tz: la)
        // Cadence 1 day: due Feb 23 09:00.
        let last = Self.date("2026-02-22 09:00", tz: la)
        let now  = Self.date("2026-03-09 09:00", tz: la)  // spans 2026-03-08 DST
        let contact = Self.makeContact(lastInteractedAt: last, cadenceDays: 1)

        let row = OverdueViewModel.makeOverdueRow(for: contact, now: now, calendar: calendar)
        #expect(row?.overdueDays == 14)
    }

    // MARK: - Happy path sanity

    @Test("Non-overdue contact returns 0")
    func notOverdue() {
        let utc = Self.makeCalendar(tz: "UTC")
        let last = Self.date("2026-04-19 12:00", tz: "UTC")
        let now = Self.date("2026-04-20 12:00", tz: "UTC")
        let contact = Self.makeContact(lastInteractedAt: last, cadenceDays: 14)

        let row = OverdueViewModel.makeOverdueRow(for: contact, now: now, calendar: utc)
        #expect(row?.overdueDays == 0)
    }

    @Test("Skipped contacts (no cadence / not tracked) return nil")
    func skipped() {
        let utc = Self.makeCalendar(tz: "UTC")
        var contact = Self.makeContact(lastInteractedAt: Date(), cadenceDays: 14)
        contact.tracked = false
        #expect(OverdueViewModel.makeOverdueRow(
            for: contact, now: Date(), calendar: utc) == nil)

        var noCadence = Self.makeContact(lastInteractedAt: Date(), cadenceDays: 14)
        noCadence.cadenceDays = nil
        #expect(OverdueViewModel.makeOverdueRow(
            for: noCadence, now: Date(), calendar: utc) == nil)
    }

    @Test("A tracked contact with a cadence of 0 days has no overdue row")
    func zeroCadenceHasNoOverdueRow() {
        let utc = Self.makeCalendar(tz: "UTC")
        let now = Self.date("2026-04-20 12:00", tz: "UTC")
        let contact = Self.makeContact(lastInteractedAt: now.addingTimeInterval(-30 * 86_400), cadenceDays: 0)

        #expect(OverdueViewModel.makeOverdueRow(for: contact, now: now, calendar: utc) == nil)
    }

    @Test("A tracked contact with a cadence of 0 days never reaches the Overdue list")
    func zeroCadenceContactIsNotListedAsOverdue() async {
        let now = OverdueViewModelActionTests.now
        let zeroCadence = OverdueViewModelActionTests.overdueContact(
            cadenceDays: 0, lastInteractedAt: now.addingTimeInterval(-30 * 86_400))
        let overdue = OverdueViewModelActionTests.overdueContact(
            cadenceDays: 7, lastInteractedAt: now.addingTimeInterval(-30 * 86_400))
        let viewModel = OverdueViewModelActionTests.viewModel(
            contacts: StubContactRepository([zeroCadence, overdue]))

        await viewModel.load()

        #expect(viewModel.rows.map(\.contactId) == [overdue.id])
    }
}
