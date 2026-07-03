import Foundation

/// Result of a cadence scheduling pass for a single contact / group.
public enum CadenceSchedulingOutcome: Sendable, Equatable {
    /// Contact is not yet overdue and has no pending reminder.
    case notOverdue(firesAt: Date)
    /// Contact is overdue (or becomes overdue when `now` reaches `targetFireTime`)
    /// and the engine has picked a next window to fire in.
    case scheduled(firesAt: Date)
    /// Contact is not tracked, has no cadence set, or its effective window can
    /// never fire (`windowHasNoCapacity`).
    case skipped(reason: SkipReason)

    public enum SkipReason: String, Sendable, Equatable {
        case notTracked
        case missingCadence
        case archived
        /// The effective window has zero firing capacity (no allowed days, no
        /// usable ranges, or quiet hours consume every slot). SchedulingPass
        /// surfaces this as a Settings badge rather than firing anyway
        /// (§9 contract 2, R4).
        case windowHasNoCapacity
    }
}

/// Month-day pair for annual-recurrence events (§7). Kept as its own type so
/// Feb-29 handling is explicit at every call site.
public struct MonthDay: Sendable, Equatable, Hashable {
    public let month: Int
    public let day: Int

    public init(month: Int, day: Int) {
        precondition(Self.isValid(month: month, day: day),
                     "\(month)-\(day) is not a valid month-day combination")
        self.month = month
        self.day = day
    }

    /// Failable equivalent of `init` — returns nil on invalid combos instead
    /// of trapping. Preferred entry point for any caller parsing untrusted
    /// input (e.g. deserialized from system Contacts or user form fields).
    public static func make(month: Int, day: Int) -> MonthDay? {
        guard isValid(month: month, day: day) else { return nil }
        return MonthDay(month: month, day: day)
    }

    /// Validate by round-tripping `(month, day)` through a Gregorian calendar
    /// anchored in a leap year (so Feb 29 passes). If Calendar has to roll the
    /// components forward — e.g. Nov 31 → Dec 1, Feb 30 → Mar 2, month 13 →
    /// year + 1 — the normalized components won't match the input and we
    /// reject. Delegates "which days exist in each month" to Foundation so
    /// the check stays correct if Foundation's calendar arithmetic ever
    /// changes (it won't, but the delegation is cleaner than a hand-rolled
    /// table).
    private static func isValid(month: Int, day: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var components = DateComponents()
        components.year = 2024   // leap year — validates Feb 29 alongside the rest
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return false }
        let normalized = calendar.dateComponents([.month, .day], from: date)
        return normalized.month == month && normalized.day == day
    }

    /// ISO "MM-DD" used as `ScheduledReminder.occasionDate`.
    public var isoString: String {
        String(format: "%02d-%02d", month, day)
    }

    public static func from(isoString: String) -> MonthDay? {
        let parts = isoString.split(separator: "-")
        guard parts.count == 2,
              let m = Int(parts[0]), let d = Int(parts[1]) else { return nil }
        return make(month: m, day: d)
    }
}

/// Pure-function reminder scheduler (ARCHITECTURE.md §9). Takes no dependency
/// on Apple platform frameworks — the platform adapter calls `schedule(for:)`
/// and translates the `Date` result into a `UNCalendarNotificationTrigger`
/// up-call.
public struct ReminderEngine: Sendable {

    /// Morning-of notification time for birthdays + anniversaries
    /// (default 09:00 local per §9). Stored on `UserProfile`/Settings in
    /// production; passed in here to keep the engine pure.
    public let occasionNotificationTime: TimeOfDay

    /// Injected clock — tests pass a fixed date.
    private let clock: @Sendable () -> Date

    public init(
        occasionNotificationTime: TimeOfDay = TimeOfDay(hour: 9),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.occasionNotificationTime = occasionNotificationTime
        self.clock = clock
    }

    // MARK: - Cadence scheduling

    /// Computes when a cadence reminder should fire for a given contact.
    ///
    /// - Parameters:
    ///   - contact: the target contact (`archivedAt`, `tracked`, `cadenceDays`
    ///     are inspected).
    ///   - effectiveLastInteractedAt: either the contact's own
    ///     `lastInteractedAt`, or, for a contact that belongs to a virtual-
    ///     merge group, the *max* of `lastInteractedAt` across the group's
    ///     members (ARCHITECTURE.md §7 "Scheduling under virtual merges").
    ///     Caller is responsible for the max computation.
    ///   - window: the effective reminder window (per-contact override, or
    ///     global).
    public func scheduleCadence(
        for contact: Contact,
        effectiveLastInteractedAt: Date?,
        window: ReminderWindow
    ) -> CadenceSchedulingOutcome {
        guard contact.archivedAt == nil else { return .skipped(reason: .archived) }
        guard contact.tracked else        { return .skipped(reason: .notTracked) }
        guard let cadenceDays = contact.cadenceDays, cadenceDays > 0 else {
            return .skipped(reason: .missingCadence)
        }

        let now = clock()

        // Never-contacted anchor is `createdAt`, not `now` (decision #29, R8):
        // a newly tracked contact becomes due one full cadence after tracking
        // started, not instantly. This matches the Overdue/Upcoming ViewModels'
        // `?? createdAt`; the old "due now" branch here disagreed with the UI.
        let anchor = effectiveLastInteractedAt ?? contact.createdAt
        let overdueAt = anchor.addingTimeInterval(TimeInterval(cadenceDays) * 86_400)

        let target = max(now, overdueAt)
        guard let fires = nextAllowedSlot(from: target, in: window) else {
            // Zero-capacity window — never fire, never schedule at a disallowed
            // instant (R4). SchedulingPass badges this in Settings.
            return .skipped(reason: .windowHasNoCapacity)
        }
        return overdueAt > now ? .notOverdue(firesAt: fires) : .scheduled(firesAt: fires)
    }

    // MARK: - Window walking

    /// A wall-clock `[start, end)` firing slot on a single day, after merging
    /// contiguous allowed ranges and subtracting quiet hours. Timezone- and
    /// date-independent (pure `TimeOfDay` math); the same list applies to every
    /// allowed day and is only materialized to an instant per-day.
    private struct WallClockSlot: Equatable {
        let start: TimeOfDay
        let end: TimeOfDay
    }

    /// Earliest instant ≥ the slot that contains or follows `date`, snapped to
    /// that slot's **start** (decision #30). Returns `nil` when the window can
    /// never fire — no allowed days, no usable ranges, or quiet hours consume
    /// every slot (R4). SchedulingPass treats `nil` as "skip + badge", never
    /// "fire anyway".
    ///
    /// Snapping to the slot start (rather than to `date`) is deliberate: every
    /// reminder landing in the same slot shares an identical `scheduledFor`, so
    /// digest batching is exact-equality by construction (§9 contract 5). When
    /// `date` falls inside an open slot the returned instant can therefore be
    /// earlier than `date`; the platform layer fires such a past instant
    /// immediately.
    ///
    /// All candidate instants are materialized with wall-clock calendar APIs
    /// (`date(bySettingHour:…)`), never `startOfDay + minutes` — the latter adds
    /// elapsed time and lands 60 minutes off across a DST transition, firing
    /// outside the user's declared window (R1). After materializing, each
    /// candidate is re-validated against the slot: on a spring-forward gap where
    /// the slot start doesn't exist, `date(bySettingHour:…)` yields the next
    /// existing instant, which we accept only if it still reads a wall-clock
    /// time inside the slot; otherwise the slot is skipped.
    public func nextAllowedSlot(from date: Date, in window: ReminderWindow) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = window.timeZone

        guard !window.allowedDays.isEmpty else { return nil }
        let slots = daySlots(for: window)
        guard !slots.isEmpty else { return nil }

        // 8 days guarantees we reach the next occurrence of every weekday even
        // when today's slots are all in the past.
        let searchDayStart = calendar.startOfDay(for: date)
        for dayOffset in 0..<8 {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: searchDayStart) else { continue }
            let weekday = calendar.component(.weekday, from: dayStart)
            guard window.allowedDays.contains(calendarWeekday: weekday) else { continue }

            for slot in slots {
                guard let slotStart = materialize(slot.start, onDay: dayStart, calendar: calendar),
                      let slotEnd = materialize(slot.end, onDay: dayStart, calendar: calendar) else { continue }
                // Slot entirely in the past relative to `date` — walk on.
                if slotEnd <= date { continue }
                // Re-validate the materialized start. On a spring-forward gap
                // `materialize` returns the next existing instant; if that
                // instant reads past the slot end the whole slot was skipped,
                // so keep walking (§9 contract 1).
                if wallClock(of: slotStart, calendar: calendar) >= slot.end { continue }
                return slotStart
            }
        }
        return nil
    }

    /// Wall-clock firing slots for the window: allowed ranges with wrapping /
    /// zero-length ranges dropped, contiguous ranges merged, quiet hours
    /// subtracted. Empty when the window can never fire.
    private func daySlots(for window: ReminderWindow) -> [WallClockSlot] {
        // Validation rejects wrapping allowed ranges at save time; filter them
        // (and zero-length ranges) defensively for corrupt persisted data.
        let ranges = window.allowedTimeRanges
            .filter { !$0.wrapsMidnight && $0.start != $0.end }
            .sorted { $0.start < $1.start }
        guard !ranges.isEmpty else { return [] }

        // Merge overlapping / touching ranges — contiguous ranges collapse into
        // one slot so their reminders batch together.
        var merged: [WallClockSlot] = []
        for range in ranges {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1] = WallClockSlot(start: last.start, end: max(last.end, range.end))
            } else {
                merged.append(WallClockSlot(start: range.start, end: range.end))
            }
        }

        guard let quiet = window.quietHours else { return merged }
        return merged.flatMap { subtractQuiet(quiet, from: $0) }
    }

    /// The sub-slots of `slot` left allowed once `quiet` (wrap-aware) is
    /// removed. Walks the boundary minutes inside the slot and keeps each
    /// elementary interval whose midpoint is outside quiet hours — correct for
    /// a quiet interval that clips either end of the slot or carves out its
    /// middle.
    private func subtractQuiet(_ quiet: TimeRange, from slot: WallClockSlot) -> [WallClockSlot] {
        let lo = slot.start.minutesSinceMidnight
        let hi = slot.end.minutesSinceMidnight
        var boundaries = [lo, hi]
        for edge in [quiet.start.minutesSinceMidnight, quiet.end.minutesSinceMidnight] where edge > lo && edge < hi {
            boundaries.append(edge)
        }
        boundaries.sort()

        var result: [WallClockSlot] = []
        for index in 0..<(boundaries.count - 1) {
            let lower = boundaries[index]
            let upper = boundaries[index + 1]
            if lower == upper { continue }
            let midpoint = TimeOfDay(minutesSinceMidnight: (lower + upper) / 2)
            guard !quiet.contains(midpoint) else { continue }
            let sub = WallClockSlot(start: TimeOfDay(minutesSinceMidnight: lower),
                                    end: TimeOfDay(minutesSinceMidnight: upper))
            if let last = result.last, last.end == sub.start {
                result[result.count - 1] = WallClockSlot(start: last.start, end: sub.end)
            } else {
                result.append(sub)
            }
        }
        return result
    }

    /// The actual instant on `dayStart`'s calendar day whose wall clock reads
    /// `time`, DST-aware. On a fall-back repeated hour `.first` returns the
    /// earlier of the two occurrences. On a spring-forward gap the requested
    /// time doesn't exist: `.nextTime` yields the next existing instant, which
    /// for a full-hour gap is the gap end on the same day — but for a partial
    /// gap asked at its start (e.g. Lord Howe's 30-minute shift at 02:00) it
    /// overshoots to the next day's matching time. Detect that overshoot and
    /// substitute the DST transition instant (the gap end) on this day, so a
    /// slot start inside the gap resolves to the earliest existing instant in
    /// the range rather than jumping a day (§9 contract 1, R1).
    private func materialize(_ time: TimeOfDay, onDay dayStart: Date, calendar: Calendar) -> Date? {
        guard let candidate = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0,
                                            of: dayStart, matchingPolicy: .nextTime,
                                            repeatedTimePolicy: .first, direction: .forward) else {
            return nil
        }
        if calendar.isDate(candidate, inSameDayAs: dayStart) { return candidate }
        if let transition = calendar.timeZone.nextDaylightSavingTimeTransition(after: dayStart),
           calendar.isDate(transition, inSameDayAs: dayStart) {
            return transition
        }
        return candidate
    }

    /// Wall-clock reading of `date` in `calendar`'s timezone.
    private func wallClock(of date: Date, calendar: Calendar) -> TimeOfDay {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: comps.hour ?? 0, minute: comps.minute ?? 0)
    }

    // MARK: - Annual recurrence (birthdays, anniversaries)

    /// The next occurrence of `monthDay` at `occasionNotificationTime` in the
    /// given timezone. Feb 29 falls back to Feb 28 in non-leap years.
    ///
    /// Timing (§9 contract 4):
    /// - occasion later today or on a future day → fire at `occasionNotificationTime`;
    /// - occasion is **today** and the notification time has already passed →
    ///   fire at the next possible moment today (returns `now`), so someone who
    ///   installs at noon on Mom's birthday still gets the nudge (R5);
    /// - occasion already fully passed this year → next year.
    ///
    /// Occasions ignore allowed-day/range gating by design (they're morning-of
    /// events). Quiet-hours suppression for a same-day-late occasion is applied
    /// by SchedulingPass, which owns the effective window; the pure engine
    /// returns the earliest today instant.
    public func nextOccasionOccurrence(
        monthDay: MonthDay,
        timezone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        let now = clock()
        let todayComps = calendar.dateComponents([.year, .month, .day], from: now)
        guard let thisYear = todayComps.year else { return now }

        func resolve(year: Int) -> Date? {
            let adjustedDay = resolveFeb29Fallback(year: year, monthDay: monthDay,
                                                   calendar: calendar)
            var comps = DateComponents()
            comps.year = year
            comps.month = monthDay.month
            comps.day = adjustedDay
            comps.hour = occasionNotificationTime.hour
            comps.minute = occasionNotificationTime.minute
            return calendar.date(from: comps)
        }

        if let thisYearDate = resolve(year: thisYear) {
            if thisYearDate >= now { return thisYearDate }
            // Notification time has passed. If the occasion day is still today,
            // fire now rather than rolling a full year forward (R5).
            if calendar.isDate(thisYearDate, inSameDayAs: now) { return now }
        }
        // Already fully passed this year — roll forward.
        return resolve(year: thisYear + 1) ?? now
    }

    /// Returns the effective day for the occurrence — Feb 29 in a non-leap
    /// year becomes Feb 28 (§9).
    func resolveFeb29Fallback(year: Int, monthDay: MonthDay, calendar: Calendar) -> Int {
        guard monthDay.month == 2, monthDay.day == 29 else { return monthDay.day }
        var comps = DateComponents()
        comps.year = year
        comps.month = 2
        comps.day = 1
        guard let feb1 = calendar.date(from: comps),
              let dayCount = calendar.range(of: .day, in: .month, for: feb1)?.count else {
            return 28
        }
        return dayCount >= 29 ? 29 : 28
    }

    // MARK: - Batching

    /// Group reminders that share a window slot (same `scheduledFor`) so the
    /// platform adapter can collapse them into a single digest notification
    /// (§9 "Batching").
    public func batch(_ reminders: [ScheduledReminder]) -> [Date: [ScheduledReminder]] {
        Dictionary(grouping: reminders.filter { $0.state == .pending },
                   by: { $0.scheduledFor })
    }
}
