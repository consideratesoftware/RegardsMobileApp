import Foundation
import Testing
@testable import Regards

/// DST-transition and fractional-offset-timezone coverage for `nextAllowedSlot`
/// (ARCHITECTURE.md §9 contract 1, R1). The 2026 US transitions are Sundays, so
/// these windows deliberately include Sunday — the shipped weekday-only tests
/// dodged the wall-clock bug. `Australia/Lord_Howe` exercises the 30-minute DST
/// shift. Transition instants verified against the tz database:
///   LA spring-forward: Sun Mar 8 2026, 02:00 → 03:00
///   LA fall-back:      Sun Nov 1 2026, 02:00 → 01:00
///   Lord Howe:         Sun Oct 4 2026, 02:00 → 02:30
struct ReminderEngineDSTTests {

    @Test("Spring-forward does not skip the day's first slot (weekday window, America/Los_Angeles)")
    func springForwardWeekdayWindow() {
        // Sat Mar 7 12:00; Mon–Fri 18:00–22:00. Next slot is Mon Mar 9 18:00
        // (weekend skipped; the Sun transition is irrelevant here).
        let window = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
            quietHours: nil, timezoneIdentifier: "America/Los_Angeles")
        let now = EngineFixtures.date("2026-03-07 12:00", tz: "America/Los_Angeles")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == EngineFixtures.date("2026-03-09 18:00", tz: "America/Los_Angeles"))
    }

    @Test("Fall-back does not double-schedule an early-morning slot (America/Los_Angeles)")
    func fallBackWeekdayWindow() {
        // Fri Oct 30 09:00; Mon–Fri 07:00–08:00. Next slot Mon Nov 2 07:00 —
        // single occurrence, not repeated by the Nov 1 fall-back.
        let window = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 8))],
            quietHours: nil, timezoneIdentifier: "America/Los_Angeles")
        let now = EngineFixtures.date("2026-10-30 09:00", tz: "America/Los_Angeles")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == EngineFixtures.date("2026-11-02 07:00", tz: "America/Los_Angeles"))
    }

    @Test("Evening slot ON the spring-forward day (Sun Mar 8) reads the correct wall-clock time")
    func springForwardOnTransitionDayEveningSlot() {
        // Sunday-inclusive window, on the transition day, far from the 02:00 gap.
        // 18:00 must read 18:00 wall-clock, not 17:00/19:00.
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 19))],
            tz: "America/Los_Angeles")
        let now = EngineFixtures.date("2026-03-08 12:00", tz: "America/Los_Angeles")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == EngineFixtures.date("2026-03-08 18:00", tz: "America/Los_Angeles"))
    }

    @Test("Spring-forward nonexistent slot-start takes the earliest existing instant in the range")
    func springForwardNonexistentSlotStart() {
        // Range [02:30, 05:00) on Sun Mar 8: 02:30 is inside the skipped hour.
        // The engine materializes 03:00 — the earliest real instant in the range
        // — never a phantom 02:30 that maps outside it.
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 2, minute: 30), end: TimeOfDay(hour: 5))],
            tz: "America/Los_Angeles")
        let now = EngineFixtures.date("2026-03-08 00:30", tz: "America/Los_Angeles")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == EngineFixtures.date("2026-03-08 03:00", tz: "America/Los_Angeles"))
        if let slot {
            let wc = EngineFixtures.wallClock(slot, tz: "America/Los_Angeles")
            #expect(wc.hour == 3 && wc.minute == 0)
        }
    }

    @Test("Spring-forward slot fully inside the gap is skipped — walk to the next day")
    func springForwardWholeSlotSkippedWalksOn() {
        // [02:00, 02:45) on Sun Mar 8 is entirely inside the skipped hour, so
        // Sunday has no real instant; the walk lands on Monday's 02:00.
        let window = ReminderWindow(
            allowedDays: [.sunday, .monday],
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 2), end: TimeOfDay(hour: 2, minute: 45))],
            quietHours: nil, timezoneIdentifier: "America/Los_Angeles")
        let now = EngineFixtures.date("2026-03-08 00:30", tz: "America/Los_Angeles")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == EngineFixtures.date("2026-03-09 02:00", tz: "America/Los_Angeles"))
    }

    @Test("Fall-back duplicated hour disambiguates to the FIRST occurrence")
    func fallBackDuplicatedHourFirstOccurrence() {
        // Sun Nov 1: 01:00–02:00 happens twice. Range [01:00, 02:00) must
        // materialize the earlier 01:00 (PDT), not the later (PST).
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 2))],
            tz: "America/Los_Angeles")
        let now = EngineFixtures.date("2026-11-01 00:30", tz: "America/Los_Angeles")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        // 00:30 PDT + 30 min = the FIRST 01:00 (unambiguous by construction).
        let firstOccurrence = now.addingTimeInterval(30 * 60)
        #expect(slot == firstOccurrence)
        // The SECOND 01:00 is one hour later; the engine must not pick it.
        #expect(slot != firstOccurrence.addingTimeInterval(3600))
    }

    @Test("Evening slot ON the fall-back day (Sun Nov 1) reads the correct wall-clock time")
    func fallBackOnTransitionDayEveningSlot() {
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 19))],
            tz: "America/Los_Angeles")
        let now = EngineFixtures.date("2026-11-01 12:00", tz: "America/Los_Angeles")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == EngineFixtures.date("2026-11-01 18:00", tz: "America/Los_Angeles"))
    }

    // MARK: - Half-hour-offset zone (Australia/Lord_Howe, 30-min DST shift)

    @Test("30-min-offset zone: evening slot reads the correct wall-clock time")
    func lordHoweExactSlot() {
        // Lord Howe is UTC+10:30 / +11:00. On the Oct 4 2026 transition day, a
        // far-from-gap 18:00 slot must still read exactly 18:00.
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 19))],
            tz: "Australia/Lord_Howe")
        let now = EngineFixtures.date("2026-10-04 12:00", tz: "Australia/Lord_Howe")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == EngineFixtures.date("2026-10-04 18:00", tz: "Australia/Lord_Howe"))
    }

    @Test("30-min-offset zone: spring-forward gap (02:00→02:30) takes the earliest existing instant")
    func lordHoweSpringForwardGap() {
        // Oct 4 2026: clocks jump 02:00 → 02:30 (30-min gap). Range [02:00,04:00)
        // must materialize 02:30, the first real instant in the range.
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 2), end: TimeOfDay(hour: 4))],
            tz: "Australia/Lord_Howe")
        let now = EngineFixtures.date("2026-10-04 00:30", tz: "Australia/Lord_Howe")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == EngineFixtures.date("2026-10-04 02:30", tz: "Australia/Lord_Howe"))
        if let slot {
            let wc = EngineFixtures.wallClock(slot, tz: "Australia/Lord_Howe")
            #expect(wc.hour == 2 && wc.minute == 30)
        }
    }
}
