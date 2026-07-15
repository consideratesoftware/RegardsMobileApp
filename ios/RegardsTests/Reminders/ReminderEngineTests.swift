import Foundation
import Testing
@testable import Regards

/// Shared fixtures for the engine suites. Kept in one place so the cadence and
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

    static func engine(now: Date) -> ReminderEngine {
        ReminderEngine(clock: { now })
    }
}

/// Core ReminderEngine algorithm from ARCHITECTURE.md §9 — cadence resolution,
/// window walking, degenerate handling, slot-start snapping, batching.
struct ReminderEngineTests {

    // MARK: - Basic cadence

    @Test("Contact overdue right now schedules in the next in-window slot")
    func cadenceOverdueNow() {
        // Wed 2026-04-15 14:00 local (between 13:00-18:00 gap) — not in window.
        let now = EngineFixtures.date("2026-04-15 14:00", tz: "Asia/Kolkata")
        let last = EngineFixtures.date("2026-03-29 09:00", tz: "Asia/Kolkata")  // 17 days ago
        let contact = Contact(
            systemContactRef: "x", displayName: "Test",
            tracked: true, cadenceDays: 14,
            priorityTier: .regular, preferredChannel: .whatsapp,
            preferredChannelValue: "+15551234567",
            lastInteractedAt: last)

        let outcome = EngineFixtures.engine(now: now).scheduleCadence(
            for: contact, effectiveLastInteractedAt: last, window: EngineFixtures.indiaWindow)

        guard case .scheduled(let fires) = outcome else {
            Issue.record("expected scheduled outcome, got \(outcome)"); return
        }
        // Next slot opens 18:00 the same Wed.
        #expect(fires == EngineFixtures.date("2026-04-15 18:00", tz: "Asia/Kolkata"))
    }

    @Test("Not-yet-overdue contact is still scheduled, not marked overdue")
    func cadenceNotYetOverdue() {
        let now = EngineFixtures.date("2026-04-15 14:00", tz: "Asia/Kolkata")
        let last = EngineFixtures.date("2026-04-14 09:00", tz: "Asia/Kolkata")
        let contact = Contact(
            systemContactRef: "x", displayName: "Test",
            tracked: true, cadenceDays: 14, preferredChannel: .whatsapp,
            preferredChannelValue: "+15551234567",
            lastInteractedAt: last)

        let outcome = EngineFixtures.engine(now: now).scheduleCadence(
            for: contact, effectiveLastInteractedAt: last, window: EngineFixtures.indiaWindow)
        if case .notOverdue = outcome { return }
        Issue.record("expected notOverdue, got \(outcome)")
    }

    @Test("Skipped when contact not tracked")
    func cadenceSkippedWhenNotTracked() {
        let now = Date()
        var contact = Contact(systemContactRef: "x", displayName: "A",
                              preferredChannel: .whatsapp, preferredChannelValue: "")
        contact.tracked = false
        let outcome = EngineFixtures.engine(now: now).scheduleCadence(
            for: contact, effectiveLastInteractedAt: nil, window: EngineFixtures.indiaWindow)
        #expect(outcome == .skipped(reason: .notTracked))
    }

    @Test("Skipped when cadence is missing")
    func cadenceSkippedWhenMissing() {
        let contact = Contact(systemContactRef: "x", displayName: "A",
                              tracked: true, cadenceDays: nil,
                              preferredChannel: .whatsapp, preferredChannelValue: "")
        let outcome = EngineFixtures.engine(now: Date()).scheduleCadence(
            for: contact, effectiveLastInteractedAt: nil, window: EngineFixtures.indiaWindow)
        #expect(outcome == .skipped(reason: .missingCadence))
    }

    @Test("Archived contacts are skipped")
    func cadenceSkippedWhenArchived() {
        var contact = Contact(systemContactRef: "x", displayName: "A",
                              tracked: true, cadenceDays: 7,
                              preferredChannel: .whatsapp, preferredChannelValue: "")
        contact.archivedAt = Date()
        let outcome = EngineFixtures.engine(now: Date()).scheduleCadence(
            for: contact, effectiveLastInteractedAt: nil, window: EngineFixtures.indiaWindow)
        #expect(outcome == .skipped(reason: .archived))
    }

    // MARK: - Never-contacted anchor = createdAt (decision #29, R8)

    @Test("Never-contacted contact is NOT instantly overdue — due one cadence after createdAt")
    func cadenceNeverContactedNotYetDue() {
        // Created 5 hours ago; cadence 7 days. Must not flood the first-run
        // Overdue screen. Anchor is createdAt, so it's notOverdue.
        let created = EngineFixtures.date("2026-04-15 09:00", tz: "Asia/Kolkata")
        let now = EngineFixtures.date("2026-04-15 14:00", tz: "Asia/Kolkata")
        let contact = Contact(
            systemContactRef: "x", displayName: "Test", tracked: true,
            cadenceDays: 7, preferredChannel: .whatsapp,
            preferredChannelValue: "+15551234567",
            lastInteractedAt: nil, createdAt: created)
        let outcome = EngineFixtures.engine(now: now).scheduleCadence(
            for: contact, effectiveLastInteractedAt: nil, window: EngineFixtures.indiaWindow)
        if case .notOverdue = outcome { return }
        Issue.record("expected notOverdue (createdAt anchor), got \(outcome)")
    }

    @Test("Never-contacted contact becomes overdue exactly one cadence after createdAt")
    func cadenceNeverContactedOverdue() {
        // Created 14 days ago, cadence 7 → overdue since createdAt + 7d.
        let created = EngineFixtures.date("2026-04-01 09:00", tz: "Asia/Kolkata")
        let now = EngineFixtures.date("2026-04-15 14:00", tz: "Asia/Kolkata")
        let contact = Contact(
            systemContactRef: "x", displayName: "Test", tracked: true,
            cadenceDays: 7, preferredChannel: .whatsapp,
            preferredChannelValue: "+15551234567",
            lastInteractedAt: nil, createdAt: created)
        let outcome = EngineFixtures.engine(now: now).scheduleCadence(
            for: contact, effectiveLastInteractedAt: nil, window: EngineFixtures.indiaWindow)
        guard case .scheduled(let fires) = outcome else {
            Issue.record("expected scheduled, got \(outcome)"); return
        }
        #expect(fires == EngineFixtures.date("2026-04-15 18:00", tz: "Asia/Kolkata"))
    }

    // MARK: - Degenerate window → skipped (R4)

    @Test("Zero-capacity window skips with windowHasNoCapacity instead of scheduling illegally")
    func cadenceZeroCapacityWindowSkips() {
        let deadWindow = ReminderWindow(
            allowedDays: .weekdays, allowedTimeRanges: [],
            quietHours: nil, timezoneIdentifier: "Asia/Kolkata")
        let last = EngineFixtures.date("2026-03-01 09:00", tz: "Asia/Kolkata")
        let contact = Contact(
            systemContactRef: "x", displayName: "Test", tracked: true,
            cadenceDays: 7, preferredChannel: .whatsapp,
            preferredChannelValue: "+15551234567", lastInteractedAt: last)
        let now = EngineFixtures.date("2026-04-15 14:00", tz: "Asia/Kolkata")
        let outcome = EngineFixtures.engine(now: now).scheduleCadence(
            for: contact, effectiveLastInteractedAt: last, window: deadWindow)
        #expect(outcome == .skipped(reason: .windowHasNoCapacity))
    }

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

    @Test("A future cadence expiry inside a slot never fires before it is due")
    func futureCadenceExpiryWalksToNextSlot() {
        let timezone = "Asia/Kolkata"
        let now = EngineFixtures.date("2026-04-15 12:00", tz: timezone)
        let createdAt = EngineFixtures.date("2026-04-14 18:05", tz: timezone)
        let contact = Contact(
            systemContactRef: "future-inside-slot",
            displayName: "Future",
            tracked: true,
            cadenceDays: 1,
            createdAt: createdAt
        )
        let window = ReminderWindow(
            allowedDays: [.wednesday, .thursday],
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
            timezoneIdentifier: timezone
        )

        let outcome = EngineFixtures.engine(now: now).scheduleCadence(
            for: contact,
            effectiveLastInteractedAt: nil,
            window: window
        )

        #expect(outcome == .notOverdue(
            firesAt: EngineFixtures.date("2026-04-16 18:00", tz: timezone)))
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
