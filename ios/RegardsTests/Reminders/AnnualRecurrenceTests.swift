import Foundation
import Testing
@testable import Regards

struct AnnualRecurrenceTests {

    static let ist = TimeZone(identifier: "Asia/Kolkata")!

    static func date(_ iso: String, tz: TimeZone = ist) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = calendar
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = tz
        df.isLenient = false
        return df.date(from: iso)!
    }

    @Test("Birthday later this year schedules at 09:00 on the birthday")
    func birthdayLaterThisYear() {
        let now = Self.date("2026-04-19 14:00")
        let engine = ReminderEngine(
            occasionNotificationTime: TimeOfDay(hour: 9),
            clock: { now })
        let next = engine.nextOccasionOccurrence(
            monthDay: MonthDay(month: 6, day: 14),
            timezone: Self.ist)
        #expect(next == Self.date("2026-06-14 09:00"))
    }

    @Test("Birthday already passed this year rolls into next year")
    func birthdayAlreadyPassed() {
        let now = Self.date("2026-04-19 14:00")
        let engine = ReminderEngine(
            occasionNotificationTime: TimeOfDay(hour: 9),
            clock: { now })
        let next = engine.nextOccasionOccurrence(
            monthDay: MonthDay(month: 3, day: 10),
            timezone: Self.ist)
        #expect(next == Self.date("2027-03-10 09:00"))
    }

    @Test("Birthday is today but before 09:00 — fires today")
    func birthdayTodayBeforeTime() {
        let now = Self.date("2026-06-14 07:00")
        let engine = ReminderEngine(
            occasionNotificationTime: TimeOfDay(hour: 9),
            clock: { now })
        let next = engine.nextOccasionOccurrence(
            monthDay: MonthDay(month: 6, day: 14),
            timezone: Self.ist)
        #expect(next == Self.date("2026-06-14 09:00"))
    }

    @Test("Birthday is today but after 09:00 — fires now, not next year (R5)")
    func birthdayTodaySameDayLateFiresToday() {
        // Install at 10:00 on Mom's birthday; the 09:00 slot has passed. The
        // shipped engine rolled a full year forward; the contract fires today at
        // the next possible moment (now).
        let now = Self.date("2026-06-14 10:00")
        let engine = ReminderEngine(
            occasionNotificationTime: TimeOfDay(hour: 9),
            clock: { now })
        let next = engine.nextOccasionOccurrence(
            monthDay: MonthDay(month: 6, day: 14),
            timezone: Self.ist)
        #expect(next == now)
    }

    @Test("Feb-29 same-day-late in a non-leap year fires today on Feb 28 (R5)")
    func feb29SameDayLateFiresToday() {
        // 2027 is non-leap: the Feb-29 occasion resolves to Feb 28. Installing
        // at 14:00 on Feb 28, after the 09:00 slot, must still fire today.
        let now = Self.date("2027-02-28 14:00")
        let engine = ReminderEngine(
            occasionNotificationTime: TimeOfDay(hour: 9),
            clock: { now })
        let next = engine.nextOccasionOccurrence(
            monthDay: MonthDay(month: 2, day: 29),
            timezone: Self.ist)
        #expect(next == now)
    }

    @Test("Feb 29 falls back to Feb 28 in non-leap years")
    func feb29NonLeapFallback() {
        // 2027 is not a leap year; 2028 is.
        let now = Self.date("2027-01-15 14:00")
        let engine = ReminderEngine(
            occasionNotificationTime: TimeOfDay(hour: 9),
            clock: { now })
        let next = engine.nextOccasionOccurrence(
            monthDay: MonthDay(month: 2, day: 29),
            timezone: Self.ist)
        #expect(next == Self.date("2027-02-28 09:00"))
    }

    @Test("Feb 29 stays Feb 29 in leap years")
    func feb29LeapYear() {
        let now = Self.date("2028-01-15 14:00")
        let engine = ReminderEngine(
            occasionNotificationTime: TimeOfDay(hour: 9),
            clock: { now })
        let next = engine.nextOccasionOccurrence(
            monthDay: MonthDay(month: 2, day: 29),
            timezone: Self.ist)
        #expect(next == Self.date("2028-02-29 09:00"))
    }

    // MARK: - Quiet hours (R5, §9 contract 4)

    private static let newYork = "America/New_York"
    private static let quietNightWindow = EngineFixtures.allDaysWindow(
        [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))],
        tz: newYork,
        quiet: TimeRange(start: TimeOfDay(hour: 22, minute: 30), end: TimeOfDay(hour: 7, minute: 30)))

    /// The instant an occasion on Jun 14 fires for `now`, through both steps
    /// SchedulingPass runs: the next occurrence, then the quiet-hours rule.
    private static func fireDate(
        now: Date, window: ReminderWindow, occasionTime: TimeOfDay = TimeOfDay(hour: 7)
    ) -> Date? {
        let engine = ReminderEngine(occasionNotificationTime: occasionTime, clock: { now })
        let occurrence = engine.nextOccasionOccurrence(
            monthDay: MonthDay(month: 6, day: 14), timezone: window.timeZone)
        return engine.occasionFireDate(for: occurrence, in: window, timeZone: window.timeZone)
    }

    @Test("An occasion time inside quiet hours fires at the quiet end the same day (R5)")
    func occasionFireDateRespectsQuietHours() {
        // 07:00 is inside quiet hours 22:30-07:30, so it waits until 07:30.
        let now = EngineFixtures.date("2026-06-13 12:00", tz: Self.newYork)

        let fire = Self.fireDate(now: now, window: Self.quietNightWindow)

        #expect(fire == EngineFixtures.date("2026-06-14 07:30", tz: Self.newYork))
    }

    @Test("A same-day-late occasion inside quiet hours that run past midnight gets no notification (R5)")
    func sameDayLateOccasionInQuietHoursIsDropped() {
        // Installed at 23:00 on the birthday: the occurrence is now, quiet hours
        // run until 07:30 tomorrow, and the occasion's day is over by then.
        let now = EngineFixtures.date("2026-06-14 23:00", tz: Self.newYork)

        let fire = Self.fireDate(now: now, window: Self.quietNightWindow)

        #expect(fire == nil)
    }

    @Test("An occasion after midnight but before the quiet end fires at the quiet end the same day (R5)")
    func sameDayEarlyMorningOccasionWaitsForQuietEnd() {
        let now = EngineFixtures.date("2026-06-14 00:15", tz: Self.newYork)

        let fire = Self.fireDate(now: now, window: Self.quietNightWindow)

        #expect(fire == EngineFixtures.date("2026-06-14 07:30", tz: Self.newYork))
    }

    @Test("A same-day-late occasion outside quiet hours still fires now (R5)")
    func sameDayLateOccasionOutsideQuietHoursFiresNow() {
        let now = EngineFixtures.date("2026-06-14 10:00", tz: Self.newYork)

        let fire = Self.fireDate(now: now, window: Self.quietNightWindow)

        #expect(fire == now)
    }

    @Test("Occasion times at the edges of quiet hours: the end fires as is, the start is dropped (R5)")
    func occasionFireDateAtQuietHoursEdges() {
        let atEnd = EngineFixtures.date("2026-06-14 07:30", tz: Self.newYork)
        let atStart = EngineFixtures.date("2026-06-14 22:30", tz: Self.newYork)
        let engine = ReminderEngine(clock: { atEnd })

        #expect(engine.occasionFireDate(
            for: atEnd, in: Self.quietNightWindow, timeZone: Self.quietNightWindow.timeZone) == atEnd)
        #expect(engine.occasionFireDate(
            for: atStart, in: Self.quietNightWindow, timeZone: Self.quietNightWindow.timeZone) == nil)
    }

    @Test("A window without quiet hours leaves the occurrence alone (R5)")
    func occasionFireDateWithoutQuietHoursIsUnchanged() {
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))], tz: Self.newYork)
        let occurrence = EngineFixtures.date("2026-06-14 03:00", tz: Self.newYork)

        let engine = ReminderEngine(clock: { occurrence })
        #expect(engine.occasionFireDate(for: occurrence, in: window, timeZone: window.timeZone) == occurrence)
    }

    @Test("A quiet range that does not wrap midnight moves the occasion to its end (R5)")
    func occasionFireDateWithDaytimeQuietHours() {
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))],
            tz: Self.newYork,
            quiet: TimeRange(start: TimeOfDay(hour: 6), end: TimeOfDay(hour: 8)))
        let now = EngineFixtures.date("2026-06-13 12:00", tz: Self.newYork)

        let fire = Self.fireDate(now: now, window: window)

        #expect(fire == EngineFixtures.date("2026-06-14 08:00", tz: Self.newYork))
    }

    @Test("A quiet end inside the spring-forward gap fires at the gap end (R5)")
    func occasionFireDateQuietEndInSpringForwardGap() {
        // Sun Mar 8 2026 in Los Angeles: 02:00 -> 03:00. Quiet 01:30-02:30 ends
        // at a time that does not exist that day.
        let zone = "America/Los_Angeles"
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))],
            tz: zone,
            quiet: TimeRange(start: TimeOfDay(hour: 1, minute: 30), end: TimeOfDay(hour: 2, minute: 30)))
        let occurrence = EngineFixtures.date("2026-03-08T01:45:00-08:00")

        let engine = ReminderEngine(clock: { occurrence })
        let fire = engine.occasionFireDate(for: occurrence, in: window, timeZone: window.timeZone)

        #expect(fire == EngineFixtures.date("2026-03-08T03:00:00-07:00"))
    }

    @Test("A quiet end in the fall-back repeated hour fires at the later occurrence (R5)")
    func occasionFireDateQuietEndInFallBackRepeatedHour() {
        // Sun Nov 1 2026 in Los Angeles: 01:00-02:00 happens twice. Quiet
        // 00:30-01:30 covers 01:00-01:30 again after the clock falls back, so
        // it ends at the second 01:30, not the first.
        let zone = "America/Los_Angeles"
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))],
            tz: zone,
            quiet: TimeRange(start: TimeOfDay(hour: 0, minute: 30), end: TimeOfDay(hour: 1, minute: 30)))
        let occurrence = EngineFixtures.date("2026-11-01T00:45:00-07:00")

        let engine = ReminderEngine(clock: { occurrence })
        let fire = engine.occasionFireDate(for: occurrence, in: window, timeZone: window.timeZone)

        #expect(fire == EngineFixtures.date("2026-11-01T01:30:00-08:00"))
    }

    @Test("MonthDay encodes to and from the ISO MM-DD form")
    func monthDayIsoRoundtrip() {
        #expect(MonthDay(month: 2, day: 29).isoString == "02-29")
        #expect(MonthDay.from(isoString: "12-31") == MonthDay(month: 12, day: 31))
        #expect(MonthDay.from(isoString: "13-01") == nil)
        #expect(MonthDay.from(isoString: "not-a-date") == nil)
    }

    @Test("MonthDay.make rejects day-of-month values impossible for the given month")
    func monthDayRejectsInvalidCombinations() {
        // 30-day months have no 31st.
        #expect(MonthDay.make(month: 4,  day: 31) == nil) // April
        #expect(MonthDay.make(month: 6,  day: 31) == nil) // June
        #expect(MonthDay.make(month: 9,  day: 31) == nil) // September
        #expect(MonthDay.make(month: 11, day: 31) == nil) // November — review comment

        // February has no 30th or 31st; 29 is allowed (leap-year fallback).
        #expect(MonthDay.make(month: 2, day: 30) == nil)
        #expect(MonthDay.make(month: 2, day: 31) == nil)
        #expect(MonthDay.make(month: 2, day: 29) != nil)

        // End-of-month boundaries for the 31-day months.
        #expect(MonthDay.make(month: 1,  day: 31) != nil)
        #expect(MonthDay.make(month: 12, day: 31) != nil)

        // Out-of-range guards.
        #expect(MonthDay.make(month: 0,  day: 1)  == nil)
        #expect(MonthDay.make(month: 13, day: 1)  == nil)
        #expect(MonthDay.make(month: 1,  day: 0)  == nil)
        #expect(MonthDay.make(month: 1,  day: -1) == nil)
    }

    @Test("ISO parser rejects impossible day-month combinations too")
    func isoStringRejectsInvalidCombinations() {
        #expect(MonthDay.from(isoString: "11-31") == nil) // Nov 31
        #expect(MonthDay.from(isoString: "02-30") == nil) // Feb 30
        #expect(MonthDay.from(isoString: "04-31") == nil) // Apr 31
        #expect(MonthDay.from(isoString: "02-29") != nil) // Feb 29 still allowed
    }
}
