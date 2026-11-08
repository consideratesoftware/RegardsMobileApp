import Foundation

/// The sole writer of `ScheduledReminder` rows (§9a, decision #36).
/// `runFull()` and `run(for:)` derive every pending row from the contacts,
/// the global window, per-contact overrides and the injected occasions;
/// Snooze and `recordInteraction` write through the same lock.
///
/// **Derivation (§9).** A cadence row's `scheduledFor` is
/// `nextAllowedSlot(max(now, overdueAt, snoozedUntil))` in the contact's
/// effective window (`reminderWindowOverride ?? global`), moved past the
/// day of any occasion of the same contact that will notify (contract 6).
/// An occasion row's `scheduledFor` is its next occurrence at the global
/// `occasionTime`, moved out of the effective window's quiet hours by
/// `ReminderEngine.occasionFireDate`, or the occurrence itself when quiet
/// hours run past its day (owner ruling 9: the row stays, no notification).
///
/// **Per-pass window (R55).** Every run reads the global window and builds
/// its calendar from that window's timezone. Nothing is cached, so a window
/// edit never leaves the pass on a stale zone or needs a second pass.
///
/// **Fired marking and no re-nag (§9 "Notification fired", owner ruling 5).**
/// Each run first marks covered pending rows at or before `now` fired. Fired
/// rows are history and never cancelled. A fired cadence row stays until an interaction
/// or a longer cadence starts a new cycle; a clock rollback can re-arm it only after a window edit (R68).
///
/// **Corrupt rows.** Runs read one `fetchSchedule()` snapshot, which drops
/// an undecodable contact (with its rows) or row. The pass never cancels what
/// it can't decode, one bad row never stops scheduling for everyone else, and
/// a write at an undecodable row's id replaces it. The orphan sweep's reads
/// fail closed and skip only the sweep: `runFull()` over any undecodable
/// pending row, `run(for:)` only over that contact's.
public actor SchedulingPass {
    private let reminders: any ReminderRepository
    private let contacts: any ContactRepository
    private let interactions: any InteractionRepository
    private let window: any ReminderWindowRepository
    private let occasions: @Sendable ([Contact]) async -> [ContactOccasion]
    private let clock: @Sendable () -> Date

    /// Contacts whose effective window has zero capacity, as of the last run
    /// that covered them (§9 contract 2, R4). No row is written for them.
    /// TF-07g shows the Settings badge from this.
    public private(set) var zeroCapacityContactIds: Set<UUID> = []

    /// One FIFO lock over every mutation (R59). Each mutation suspends
    /// between its reads and its writes, and an actor is reentrant at every
    /// suspension; the lock keeps a decision made before a suspension from
    /// being applied after someone else's write.
    ///
    /// **Load-bearing premise: one instance.** The lock is actor state, so it
    /// serialises only callers sharing this `SchedulingPass`. `AppRuntime`
    /// holds exactly one and every screen gets that one.
    private var isBusy = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until no other mutation is in flight. Always pair with
    /// `unlock` via `defer`.
    private func lock() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { lockWaiters.append($0) }
        // `unlock` hands the lock over without releasing it, so it is held
        // on our behalf here and no third caller can slip in between.
    }

    private func unlock() {
        guard !lockWaiters.isEmpty else {
            isBusy = false
            return
        }
        lockWaiters.removeFirst().resume()
    }

    /// `interactions`, `window` and `occasions` have no default: a silent
    /// fallback is the R9 bug. Production passes an `occasions` that returns
    /// `[]` until PR30 reads Contacts and Calendar.
    public init(
        reminders: any ReminderRepository,
        contacts: any ContactRepository,
        interactions: any InteractionRepository,
        window: any ReminderWindowRepository,
        occasions: @escaping @Sendable ([Contact]) async -> [ContactOccasion],
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reminders = reminders
        self.contacts = contacts
        self.interactions = interactions
        self.window = window
        self.occasions = occasions
        self.clock = clock
    }

    // MARK: - Runs

    /// Launch, foreground, and global-window reconcile (§9a). Idempotent: a
    /// second run on the same clock makes no writes.
    public func runFull() async throws {
        await lock()
        defer { unlock() }
        try await reschedule(only: nil)
    }

    /// One contact's reconcile, after an override edit.
    public func run(for contactId: UUID) async throws {
        await lock()
        defer { unlock() }
        try await reschedule(only: contactId)
    }

    /// Writes the rows the snapshot says should exist, for every tracked
    /// contact or only `contactId`, and cancels future pending rows that shouldn't; a due one is marked fired first.
    private func reschedule(only contactId: UUID?) async throws {
        // One read holds the contacts, the pending and fired rows, and the
        // window. A one-shot fetch, never the observation: GRDB delivers that
        // on the main queue, and this await holds the lock (R66).
        let snapshot = try await reminders.fetchSchedule()
        let context = Context(now: clock(), global: snapshot.window)
        let (now, global, calendar) = (context.now, context.global, context.calendar)
        let targets = snapshot.contacts.filter { contactId == nil || $0.id == contactId }
        let targetIds = Set(targets.map(\.id))
        // §9 "Notification fired": a due covered pending row is treated as delivered and marked fired. Rows this
        // call writes at or before now are written fired, so after a run that returns, no covered pending row is due.
        var rows = snapshot.reminders
        for (index, row) in rows.enumerated()
        where row.state == .pending && row.scheduledFor <= now && targetIds.contains(row.contactId) {
            guard try await reminders.transitionState(id: row.id, from: .pending, to: .fired) else { continue }
            rows[index].state = .fired
        }
        let allOccasions = await occasions(targets)
        let existingById = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var desiredIds = Set<UUID>()
        var zeroCapacity = Set<UUID>()
        for contact in targets {
            let effective = contact.reminderWindowOverride ?? global
            let occurrences = Self.nearestOccurrences(
                of: allOccasions.filter { $0.contactId == contact.id },
                context: context
            )
            for (occasion, occurrence) in occurrences {
                let id = Self.reminderID(contactId: contact.id, kind: occasion.kind)
                desiredIds.insert(id)
                // A same-day occasion that has fired (marking fires a due one) stays put,
                // so a "fire now" occurrence can't chase the clock or a rollback re-arm it.
                if let existing = existingById[id], existing.state == .fired,
                   calendar.isDate(existing.scheduledFor, inSameDayAs: occurrence) {
                    continue
                }
                var desired = ScheduledReminder(
                    id: id,
                    contactId: contact.id,
                    kind: occasion.kind,
                    occasionDate: occasion.monthDay.isoString,
                    occasionLabel: occasion.label,
                    scheduledFor: context.engine.occasionFireDate(
                        for: occurrence,
                        in: effective,
                        timeZone: calendar.timeZone
                    ) ?? occurrence,
                    osNotificationId: Self.notificationId(contactId: contact.id, kind: occasion.kind)
                )
                if desired.scheduledFor <= now { desired.state = .fired }
                if existingById[id] != desired { try await reminders.upsert(desired) }
            }

            guard contact.isCadenceEligible, let cadenceDays = contact.cadenceDays else { continue }
            let id = Self.reminderID(contactId: contact.id, kind: .cadence)
            let existing = existingById[id]
            let anchor = contact.lastInteractedAt ?? contact.createdAt
            let overdueAt = anchor.addingTimeInterval(TimeInterval(cadenceDays) * 86_400)
            // The floor governs only while its slot is still ahead; once that
            // slot has started the snooze is spent.
            let floor = existing.flatMap { $0.state == .pending && $0.scheduledFor > now ? $0.snoozedUntil : nil }
            // Capacity first: zero capacity records the contact, and the sweep below cancels the pending row.
            guard let slot = Self.cadenceSlot(
                overdueAt: overdueAt,
                floor: floor,
                window: effective,
                occurrences: occurrences.map(\.1),
                context: context
            ) else {
                // The sweep below cancels the pending row, floor and all, so a
                // snooze doesn't survive a capacity loss. Accepted: the editors
                // refuse to save a zero-capacity window (PR #67 review).
                zeroCapacity.insert(contact.id)
                continue
            }
            desiredIds.insert(id)
            // No re-nag: a fired row stays while it is this cycle's: at or after the start of the slot holding
            // overdueAt, or of the next slot if none does (a 25-hour day's 1-day cadence starts before its anchor;
            // a clock set back leaves overdueAt ahead of now), or, once overdue, at or after the anchor (a window
            // edit). No overdue check on the first: a fired row still here was written after the last interaction.
            if let existing, existing.state == .fired,
               context.engine.nextAllowedSlot(from: overdueAt, in: effective, includingContainingSlot: true)
                .map({ $0 <= existing.scheduledFor }) == true
                || (overdueAt <= now && anchor <= existing.scheduledFor) {
                continue
            }
            let desired = ScheduledReminder(
                id: id,
                contactId: contact.id,
                kind: .cadence,
                scheduledFor: slot,
                osNotificationId: Self.notificationId(contactId: contact.id, kind: .cadence),
                state: slot <= now ? .fired : .pending,
                snoozedUntil: floor
            )
            if existing != desired { try await reminders.upsert(desired) }
        }

        // Pending rows of covered contacts that no longer belong: a cadence
        // that went away, a zero-capacity window, an occasion that's gone, a
        // non-canonical id. Fired rows are history and stay.
        for row in rows
        where row.state == .pending && targetIds.contains(row.contactId) && !desiredIds.contains(row.id) {
            try await reminders.transitionState(id: row.id, from: .pending, to: .cancelled)
        }
        try await sweepOrphans(snapshotContactIds: Set(snapshot.contacts.map(\.id)), only: contactId, now: now)

        if let contactId {
            zeroCapacityContactIds.remove(contactId)
            zeroCapacityContactIds.formUnion(zeroCapacity)
        } else {
            zeroCapacityContactIds = zeroCapacity
        }
    }

    /// Retires pending rows whose contact the snapshot doesn't hold (untracked or archived, so the
    /// snapshot can't show them). A due row was delivered, so it becomes fired history and a returning
    /// contact keeps the no-re-nag hold (§9 "Notification fired"); a future row is cancelled.
    private func sweepOrphans(snapshotContactIds: Set<UUID>, only contactId: UUID?, now: Date) async throws {
        if let contactId, snapshotContactIds.contains(contactId) { return }
        let pending: [ScheduledReminder]
        do {
            if let contactId {
                pending = try await reminders.fetchPending(forContact: contactId)
            } else {
                pending = try await reminders.fetchAllPending()
            }
        } catch {
            // The fail-closed read hit an undecodable row and fails every run
            // until that row is fixed or replaced, so orphans stay pending.
            // Until TF-07f that row also hides every snooze and Upcoming
            // occasion row. The type only: an error can carry row or contact values.
            let errorType = String(describing: type(of: error))
            Self.log.error("orphan sweep skipped: \(errorType, privacy: .public)")
            return
        }
        for row in pending where !snapshotContactIds.contains(row.contactId) {
            // Only a contact that decodes as untracked or archived has its rows retired. `try?` leaves the row
            // alone for a contact that fails to decode (the snapshot's policy) or a failed read (the next
            // run retries). A contact tracked since the snapshot is the next run's to schedule.
            guard let contact = try? await contacts.fetch(id: row.contactId),
                  !(contact.tracked && contact.isActive) else { continue }
            let retired: ReminderState = row.scheduledFor <= now ? .fired : .cancelled
            try await reminders.transitionState(id: row.id, from: .pending, to: retired)
        }
    }

    // MARK: - Derivation

    /// What one run (or one snooze) derives rows from: a single `now`, and
    /// the calendar and engine built from that run's global window (R55).
    private struct Context {
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
    private static func cadenceSlot(
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
    private static func nearestOccurrences(
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

    // MARK: - Snooze and caught up

    /// Snooze 1 week (decision #31, owner ruling 1): the floor is the tap time
    /// plus 7 calendar days in the global window's timezone, and
    /// `scheduledFor` is that floor resolved into the contact's effective
    /// window by the same derivation `runFull()` uses, so the next run
    /// rewrites nothing (R57's write half). State stays `.pending`; no
    /// interaction is logged and `lastInteractedAt` never moves.
    ///
    /// Calendar days, not `7 * 86_400` seconds: elapsed time crosses a DST
    /// transition at a different wall-clock time (§9 contract 1). Repeating a
    /// snooze replaces the floor with one week from this tap.
    ///
    /// Returns `false` without writing for a contact that isn't
    /// `isCadenceEligible` (R54: checked here because a caller can act on a
    /// stale contact), a failed contact read, or a zero-capacity window.
    /// Throws when the window read or the write fails.
    @discardableResult
    public func snooze(contactId: UUID) async throws -> Bool {
        await lock()
        defer { unlock() }
        // `try?`: a failed read refuses like an ineligible contact, and the
        // caller learns it from the `false` return.
        guard let contact = try? await contacts.fetch(id: contactId), contact.isCadenceEligible,
              let cadenceDays = contact.cadenceDays else { return false }
        let global = try await window.fetchGlobal()
        let context = Context(now: clock(), global: global)
        let now = context.now
        let week = context.calendar.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86_400)
        // Whole seconds, as the row stores it, so the next run resolves the
        // stored floor to the same slot this write does.
        let floor = Date(timeIntervalSince1970: week.timeIntervalSince1970.rounded(.down))
        let occurrences = Self.nearestOccurrences(
            of: await occasions([contact]).filter { $0.contactId == contactId },
            context: context
        )
        let anchor = contact.lastInteractedAt ?? contact.createdAt
        guard let slot = Self.cadenceSlot(
            overdueAt: anchor.addingTimeInterval(TimeInterval(cadenceDays) * 86_400),
            floor: floor,
            window: contact.reminderWindowOverride ?? global,
            occurrences: occurrences.map(\.1),
            context: context
        ) else {
            return false
        }
        try await reminders.upsert(ScheduledReminder(
            id: Self.reminderID(contactId: contactId, kind: .cadence),
            contactId: contactId,
            kind: .cadence,
            scheduledFor: slot,
            osNotificationId: Self.notificationId(contactId: contactId, kind: .cadence),
            state: .pending,
            snoozedUntil: floor
        ))
        return true
    }

    /// Caught up and Log other (§9 re-evaluation triggers, R60) in one lock
    /// span: `.pending` or `.fired` to `.userCaughtUp` on the cadence row (a
    /// compare-and-set, never an insert, R59), log through
    /// `InteractionLogging`, then `reschedule(only:)`, never `run(for:)`,
    /// which would wait on this lock. The transition comes first so every
    /// `lastInteractedAt` broadcast lands after the snooze is gone.
    ///
    /// If logging throws, a row this call cleared goes back to the state it
    /// left, floor included; the lock keeps anything else from moving it first.
    /// Then it returns `false` for a notification whose contact isn't
    /// `isCadenceEligible` (a notification can outlive tracking) and
    /// rethrows anything else. A failed reschedule after a logged interaction
    /// still returns `true`. It may have written the pending replacement
    /// before a later cancellation threw; the next run finishes the job.
    @discardableResult
    public func recordInteraction(contactId: UUID, _ interaction: Interaction) async throws -> Bool {
        await lock()
        defer { unlock() }
        let cadenceId = Self.reminderID(contactId: contactId, kind: .cadence)
        // Invariant: any fired cadence row in a snapshot was written after the contact's last recorded interaction
        // (on a 25-hour day its slot can precede it), so the no-re-nag hold never keeps a row the user answered.
        var clearedFrom: ReminderState?
        if try await reminders.transitionState(id: cadenceId, from: .pending, to: .userCaughtUp) {
            clearedFrom = .pending
        } else if try await reminders.transitionState(id: cadenceId, from: .fired, to: .userCaughtUp) {
            clearedFrom = .fired
        }
        let logging = InteractionLogging(contacts: contacts, interactions: interactions)
        do {
            switch interaction {
            case .caughtUp:
                try await logging.markCaughtUp(contactId: contactId, at: clock())
            case .caughtUpFromNotification:
                try await logging.markCaughtUp(contactId: contactId, at: clock(), requireCadenceEligible: true)
            case .other(let channel):
                try await logging.logOther(contactId: contactId, channel: channel, at: clock())
            }
        } catch {
            if let clearedFrom {
                do {
                    try await reminders.transitionState(id: cadenceId, from: .userCaughtUp, to: clearedFrom)
                } catch {
                    let errorType = String(describing: type(of: error))
                    Self.log.error("couldn't restore a cleared cadence row: \(errorType, privacy: .public)")
                }
            }
            if error is InteractionLogging.NotCadenceEligible { return false }
            throw error
        }
        do {
            try await reschedule(only: contactId)
        } catch {
            let errorType = String(describing: type(of: error))
            Self.log.error("reschedule after an interaction failed: \(errorType, privacy: .public)")
        }
        return true
    }

    /// The active snooze's resolved instant for Contact Detail (R56): the
    /// pending cadence row's `scheduledFor` when it carries a floor and is
    /// still ahead, so the screen and Overdue agree, else `nil` (a spent floor
    /// stays on its fired row). `.max()` so a stray row can't win by order.
    public func pendingSnoozeDate(contactId: UUID) async throws -> Date? {
        let now = clock()
        return try await reminders.fetchPending(forContact: contactId)
            .filter { $0.kind == .cadence && $0.snoozedUntil != nil && $0.scheduledFor > now }
            .map(\.scheduledFor)
            .max()
    }
}

// MARK: - Identity

// An extension only to keep the actor body under `type_body_length`.
extension SchedulingPass {
    private static func notificationId(contactId: UUID, kind: ReminderKind) -> String {
        "contact-\(contactId.uuidString)-\(kind.rawValue)"
    }

    /// A contact's row of one kind always lives at this id, so writers race
    /// one primary key instead of inserting duplicates (R54/R59): the UUID's
    /// bytes XORed with a 16-byte salt from the kind, deterministic across
    /// launches (unlike `Hasher`) and distinct per kind. The cadence salt is
    /// "cadence-reminder", the TF-04 derivation, so existing rows keep their
    /// ids. `uuid_t` is 16 bytes, so the indexing can't go out of bounds.
    static func reminderID(contactId: UUID, kind: ReminderKind) -> UUID {
        let salt = Array("\(kind.rawValue)-reminder".utf8.prefix(16))
        var bytes = withUnsafeBytes(of: contactId.uuid) { Array($0) }
        for index in bytes.indices {
            bytes[index] ^= salt[index % salt.count]
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static let log = RegardsLogger.feature("SchedulingPass")
}
