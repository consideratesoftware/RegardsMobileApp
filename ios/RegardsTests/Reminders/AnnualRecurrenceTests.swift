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
