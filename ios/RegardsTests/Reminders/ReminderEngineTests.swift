import Foundation
import Testing
@testable import Regards

/// Shared fixtures for the engine suites. Kept in one place so the window and
/// DST suites can't drift on window shapes or date parsing.
enum EngineFixtures {

    static func date(_ iso: String, tz: String = "UTC") -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: iso) { return d }
        // Allow "YYYY-MM-DD HH:mm" local
        guard let timezone = TimeZone(identifier: tz) else {
            preconditionFailure("Unknown test timezone: \(tz)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = calendar
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.timeZone = timezone
        df.isLenient = false
        return df.date(from: iso)!
    }

    /// Wall-clock (hour, minute) reading of an instant in a given zone — used to
    /// assert DST materialization landed on a real, in-window time.
    static func wallClock(_ date: Date, tz: String) -> (hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz) ?? .current
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? -1, comps.minute ?? -1)
    }

    static let indiaWindow = ReminderWindow(
        allowedDays: [.monday, .tuesday, .wednesday, .thursday, .friday],
        allowedTimeRanges: [
            TimeRange(start: TimeOfDay(hour: 12), end: TimeOfDay(hour: 13)),
            TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22)),
        ],
        quietHours: nil,
        timezoneIdentifier: "Asia/Kolkata"
    )

    static func allDaysWindow(_ ranges: [TimeRange], tz: String,
                              quiet: TimeRange? = nil) -> ReminderWindow {
        ReminderWindow(allowedDays: .allDays, allowedTimeRanges: ranges,
                       quietHours: quiet, timezoneIdentifier: tz)
    }

    /// Every hourly instant in `[first, last]`, so a search that fails from any
    /// starting point in a week shows up, not only from the one the author
    /// thought of.
    static func hourlyInstants(from first: Date, through last: Date) -> [Date] {
        Array(stride(from: first, through: last, by: 3_600))
    }

    static func engine(now: Date) -> ReminderEngine {
        ReminderEngine(clock: { now })
    }
}

/// Core ReminderEngine algorithm from ARCHITECTURE.md §9: window walking,
/// degenerate handling, slot-start snapping, batching. Cadence derivation
/// (eligibility, the never-contacted anchor) is the pass's, so its tests are
/// in `SchedulingPassRunFullTests` and `ContactCadenceEligibilityTests`.
struct ReminderEngineTests {

    // MARK: - Window walking

    @Test("Inside an open slot snaps back to the slot start (batching identity, R6)")
    func nextAllowedSlotInsideRange() {
        // 18:30 is inside [18:00, 22:00). Under slot-start snapping the reminder
        // anchors to 18:00, not to 18:30, so co-slot reminders batch exactly.
        let now = EngineFixtures.date("2026-04-15 18:30", tz: "Asia/Kolkata")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: EngineFixtures.indiaWindow)
        #expect(slot == EngineFixtures.date("2026-04-15 18:00", tz: "Asia/Kolkata"))
    }

    @Test("Before today's first range — jumps forward to that range's start")
    func nextAllowedSlotBeforeFirstRange() {
        let now = EngineFixtures.date("2026-04-15 09:00", tz: "Asia/Kolkata")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: EngineFixtures.indiaWindow)
        #expect(slot == EngineFixtures.date("2026-04-15 12:00", tz: "Asia/Kolkata"))
    }

    @Test("Weekend disallowed — jumps to Monday's first slot")
    func nextAllowedSlotSkipsWeekend() {
        let now = EngineFixtures.date("2026-04-18 10:00", tz: "Asia/Kolkata") // Saturday
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: EngineFixtures.indiaWindow)
        #expect(slot == EngineFixtures.date("2026-04-20 12:00", tz: "Asia/Kolkata"))
    }

    @Test("Quiet hours carve out of an allowed range — fires at the post-quiet sub-slot start")
    func nextAllowedSlotHonorsQuietHours() {
        let windowWithQuiet = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
            quietHours: TimeRange(start: TimeOfDay(hour: 20), end: TimeOfDay(hour: 21)),
            timezoneIdentifier: "Asia/Kolkata"
        )
        // Cursor lands at 20:30 (inside quiet). Post-quiet sub-slot starts 21:00.
        let now = EngineFixtures.date("2026-04-15 20:30", tz: "Asia/Kolkata")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: windowWithQuiet)
        #expect(slot == EngineFixtures.date("2026-04-15 21:00", tz: "Asia/Kolkata"))
    }

    @Test("Quiet hours that consume every slot → nil (R4)")
    func nextAllowedSlotWrappingQuietConsumesEverything() {
        // A 23:00–23:30 window fully inside wrap-quiet-hours (22:30 → 07:30) can
        // never fire. The old engine returned the input date (a disallowed
        // instant); the contract now returns nil.
        let window = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 23), end: TimeOfDay(hour: 23, minute: 30))],
            quietHours: TimeRange(start: TimeOfDay(hour: 22, minute: 30), end: TimeOfDay(hour: 7, minute: 30)),
            timezoneIdentifier: "Asia/Kolkata"
        )
        let now = EngineFixtures.date("2026-04-15 09:00", tz: "Asia/Kolkata")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == nil)
    }

    @Test("Slot-start snapping: targets minutes apart in one slot collapse to the same instant (R6)")
    func slotStartSnappingEquality() {
        let tz = "Asia/Kolkata"
        let window = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
            quietHours: nil, timezoneIdentifier: tz)
        let engine = EngineFixtures.engine(now: EngineFixtures.date("2026-04-15 12:00", tz: tz))
        let slotStart = EngineFixtures.date("2026-04-15 18:00", tz: tz)
        for clockString in ["2026-04-15 17:00", "2026-04-15 18:05", "2026-04-15 21:30"] {
            let target = EngineFixtures.date(clockString, tz: tz)
            #expect(engine.nextAllowedSlot(from: target, in: window) == slotStart)
        }
    }

    @Test("Contiguous ranges collapse into one slot")
    func contiguousRangeCollapse() {
        // [12,13) and [13,14) touch at 13:00 and act as one [12,14) slot: a
        // 13:30 target snaps to 12:00, not to 13:00.
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 12), end: TimeOfDay(hour: 13)),
             TimeRange(start: TimeOfDay(hour: 13), end: TimeOfDay(hour: 14))],
            tz: "Asia/Kolkata")
        let now = EngineFixtures.date("2026-04-15 13:30", tz: "Asia/Kolkata")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == EngineFixtures.date("2026-04-15 12:00", tz: "Asia/Kolkata"))
    }

    @Test("Walk crosses midnight to the next day's morning slot")
    func midnightBoundaryWalk() {
        let window = EngineFixtures.allDaysWindow(
            [TimeRange(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 8))],
            tz: "Asia/Kolkata")
        let now = EngineFixtures.date("2026-04-15 23:50", tz: "Asia/Kolkata")
        let slot = EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window)
        #expect(slot == EngineFixtures.date("2026-04-16 07:00", tz: "Asia/Kolkata"))
    }

    @Test("Degenerate window with no allowed days → nil")
    func degenerateWindowNoDays() {
        let window = ReminderWindow(
            allowedDays: [],
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
            quietHours: nil, timezoneIdentifier: "Asia/Kolkata")
        let now = EngineFixtures.date("2026-04-15 09:00", tz: "Asia/Kolkata")
        #expect(EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window) == nil)
    }

    @Test("Degenerate window with no allowed ranges → nil")
    func degenerateWindowNoRanges() {
        let window = ReminderWindow(
            allowedDays: .weekdays, allowedTimeRanges: [],
            quietHours: nil, timezoneIdentifier: "Asia/Kolkata")
        let now = EngineFixtures.date("2026-04-15 09:00", tz: "Asia/Kolkata")
        #expect(EngineFixtures.engine(now: now).nextAllowedSlot(from: now, in: window) == nil)
    }

    // MARK: - Batching

    @Test("Pending reminders that share a scheduledFor collapse into one batch")
    func batchGroupsBySlot() {
        let c1 = UUID(); let c2 = UUID(); let c3 = UUID()
        let slotA = EngineFixtures.date("2026-04-20 18:00", tz: "Asia/Kolkata")
        let slotB = EngineFixtures.date("2026-04-21 18:00", tz: "Asia/Kolkata")
        let reminders = [
            ScheduledReminder(contactId: c1, kind: .cadence, scheduledFor: slotA, osNotificationId: "1"),
            ScheduledReminder(contactId: c2, kind: .cadence, scheduledFor: slotA, osNotificationId: "2"),
            ScheduledReminder(contactId: c3, kind: .cadence, scheduledFor: slotB, osNotificationId: "3"),
            ScheduledReminder(contactId: c1, kind: .cadence, scheduledFor: slotA,
                              osNotificationId: "cancelled", state: .cancelled),
        ]
        let batches = ReminderEngine().batch(reminders)
        #expect(batches[slotA]?.count == 2)    // cancelled is filtered
        #expect(batches[slotB]?.count == 1)
    }
}
