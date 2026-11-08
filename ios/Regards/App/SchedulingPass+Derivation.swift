import Foundation

// In its own file to keep SchedulingPass.swift under `file_length` and the
// actor body under `type_body_length`. Internal, not private, because the
// runs and Snooze in SchedulingPass.swift call it.
extension SchedulingPass {
    // MARK: - Derivation

    /// What one run (or one snooze) derives rows from: a single `now`, and
    /// the calendar and engine built from that run's global window (R55).
    struct Context {
        let now: Date
        let global: ReminderWindow
        let calendar: Calendar
        let engine: ReminderEngine

        init(now: Date, global: ReminderWindow) {
            self.now = now
            self.global = global
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = global.timeZone
            self.calendar = calendar
            self.engine = ReminderEngine(occasionNotificationTime: global.occasionTime, clock: { now })
        }
    }

    /// The cadence slot (§9): from `max(now, overdueAt, floor)`, joining the
    /// slot in progress only for an overdue contact with no snooze (a snooze
    /// target is always a future slot start, never the slot it lands in), then
    /// past the day of any occurrence that will notify in `window` (contract
    /// 6). Nil means zero capacity.
    static func cadenceSlot(
        overdueAt: Date,
        floor: Date?,
        window: ReminderWindow,
        occurrences: [Date],
        context: Context
    ) -> Date? {
        let engine = context.engine
        guard var slot = engine.nextAllowedSlot(
            from: max(context.now, overdueAt, floor ?? .distantPast),
            in: window,
            includingContainingSlot: floor == nil && overdueAt <= context.now
        ) else { return nil }
        // Contract 6: an occasion that will notify wins its day (tech-lead
        // ruling, 2026-10-28). One that never notifies keeps its row but
        // leaves the cadence slot alone, so the contact still hears something
        // that day. Bounded by the number of occasion days, since each step
        // moves past one of them.
        let calendar = context.calendar
        let occasionDays = occurrences.filter {
            engine.occasionFireDate(for: $0, in: window, timeZone: calendar.timeZone) != nil
        }
        for _ in occasionDays {
            guard let day = occasionDays.first(where: { calendar.isDate($0, inSameDayAs: slot) }),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)),
                  let deferred = engine.nextAllowedSlot(from: nextDay, in: window, includingContainingSlot: false)
            else { break }
            slot = deferred
        }
        return slot
    }

    /// The nearest occurrence per occasion kind, in the global window's
    /// timezone and occasion time (§9 contract 4; an override's copies are
    /// never read). An invalid timezone skips every occasion, as §9 says.
    static func nearestOccurrences(
        of occasions: [ContactOccasion],
        context: Context
    ) -> [(ContactOccasion, Date)] {
        guard let zone = TimeZone(identifier: context.global.timezoneIdentifier) else { return [] }
        // Ties break on the month-day, then the label (nil before ""), so the
        // row never depends on the source's order. Two occasions with the
        // same key are canonically equivalent.
        func key(_ entry: (ContactOccasion, Date)) -> (Date, String, Int, String) {
            (entry.1, entry.0.monthDay.isoString, entry.0.label == nil ? 0 : 1, entry.0.label ?? "")
        }
        var nearest: [ReminderKind: (ContactOccasion, Date)] = [:]
        for occasion in occasions where occasion.kind != .cadence {
            let entry = (occasion, context.engine.nextOccasionOccurrence(monthDay: occasion.monthDay, timezone: zone))
            if let current = nearest[occasion.kind], key(current) <= key(entry) { continue }
            nearest[occasion.kind] = entry
        }
        return nearest.values.sorted { ($0.1, $0.0.kind.rawValue) < ($1.1, $1.0.kind.rawValue) }
    }
}
