import Foundation

/// The sole writer of `ScheduledReminder` rows (§9a, decision #36). TF-07c
/// builds the DB half: `runFull()` and `run(for:)` derive every pending row
/// from the contacts, the global window, per-contact overrides and the
/// injected occasions; Snooze and `recordInteraction` write through the same
/// lock. OS notifications arrive in TF-07e.
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
/// **No re-nag (§9 "Notification fired", owner ruling 5).** A cadence row
/// whose time has come (fired, or pending at or before `now`) is left alone
/// while the contact is still overdue, its anchor hasn't moved past the row,
/// and its window still has capacity; a zero-capacity window cancels even a
/// due pending row. Until TF-07e marks rows fired from the OS, a due pending
/// row stands in for a fired one.
///
/// **Corrupt rows.** Runs read one `observeSchedule()` snapshot, which drops
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
    /// contact or only `contactId`, and cancels pending rows that shouldn't.
    private func reschedule(only contactId: UUID?) async throws {
        // One read: the first snapshot `observeSchedule()` emits holds the
        // contacts, the pending and fired rows, and the window.
        var firstSnapshot: ScheduleSnapshot?
        for await emitted in await reminders.observeSchedule() {
            firstSnapshot = emitted
            break
        }
        guard let snapshot = firstSnapshot else { throw SnapshotUnavailable() }
        let context = Context(now: clock(), global: snapshot.window)
        let (now, global, calendar) = (context.now, context.global, context.calendar)
        let targets = snapshot.contacts.filter { contactId == nil || $0.id == contactId }
        let allOccasions = await occasions(targets)
        let existingById = Dictionary(snapshot.reminders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

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
                // A same-day occasion that is already due stays put: its
                // "fire now" occurrence would otherwise move with the clock.
                if let existing = existingById[id], existing.scheduledFor <= now,
                   calendar.isDate(existing.scheduledFor, inSameDayAs: occurrence) {
                    continue
                }
                let desired = ScheduledReminder(
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
            // Capacity first: a zero-capacity window gets its id recorded and
            // its pending row cancelled below, even when that row is due.
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
            if let existing, existing.state == .fired || existing.scheduledFor <= now,
               overdueAt <= now, anchor <= existing.scheduledFor {
                continue
            }
            let desired = ScheduledReminder(
                id: id,
                contactId: contact.id,
                kind: .cadence,
                scheduledFor: slot,
                osNotificationId: Self.notificationId(contactId: contact.id, kind: .cadence),
                snoozedUntil: floor
            )
            if existing != desired { try await reminders.upsert(desired) }
        }

        // Pending rows of covered contacts that no longer belong: a cadence
        // that went away, a zero-capacity window, an occasion that's gone, a
        // non-canonical id. Fired rows are history and stay.
        let targetIds = Set(targets.map(\.id))
        for row in snapshot.reminders
        where row.state == .pending && targetIds.contains(row.contactId) && !desiredIds.contains(row.id) {
            try await reminders.transitionState(id: row.id, from: .pending, to: .cancelled)
        }
        try await cancelOrphans(snapshotContactIds: Set(snapshot.contacts.map(\.id)), only: contactId)

        if let contactId {
            zeroCapacityContactIds.remove(contactId)
            zeroCapacityContactIds.formUnion(zeroCapacity)
        } else {
            zeroCapacityContactIds = zeroCapacity
        }
    }

    /// Cancels pending rows whose contact the snapshot doesn't hold because
    /// it is untracked or archived. The snapshot can't show those rows.
    private func cancelOrphans(snapshotContactIds: Set<UUID>, only contactId: UUID?) async throws {
        if let contactId, snapshotContactIds.contains(contactId) { return }
        let pending: [ScheduledReminder]
        do {
            if let contactId {
                pending = try await reminders.fetchPending(forContact: contactId)
            } else {
                pending = try await reminders.fetchAllPending()
            }
        } catch {
            // The fail-closed read hit an undecodable row and fails the same
            // way every run until that row is fixed or replaced, so orphans
            // stay pending (no screen shows them). Overdue and Upcoming read
            // the same fetchAllPending() until TF-07f, so meanwhile that row
            // hides every snooze and every Upcoming occasion row.
            // The type only: an error can carry row or contact values.
            let errorType = String(describing: type(of: error))
            Self.log.error("orphan sweep skipped: \(errorType, privacy: .public)")
            return
        }
        for row in pending where !snapshotContactIds.contains(row.contactId) {
            // Only a contact that decodes as untracked or archived loses its
            // rows. `try?` folds two cases into "leave the row alone": a
            // contact that fails to decode (the snapshot's policy) and a
            // failed read, which the next run retries. A contact tracked
            // since the snapshot is the next run's to schedule.
            guard let contact = try? await contacts.fetch(id: row.contactId),
                  !(contact.tracked && contact.isActive) else { continue }
            try await reminders.transitionState(id: row.id, from: .pending, to: .cancelled)
        }
    }

    /// `observeSchedule()` finished without a value: its read failed.
    struct SnapshotUnavailable: Error {}

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
              let cadenceDays = contact.cadenceDays else {
            return false
        }
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

    /// What the user did: Caught up from a screen or from a notification, or
    /// "Log other channel…" through `channel`.
    public enum Interaction: Sendable, Equatable {
        case caughtUp
        case caughtUpFromNotification
        case other(Channel)
    }

    /// Caught up and Log other (§9 re-evaluation triggers, R60) in one lock
    /// span: `.pending` to `.userCaughtUp` on the cadence row (a
    /// compare-and-set, never an insert, R59), log through
    /// `InteractionLogging`, then `reschedule(only:)`, never `run(for:)`,
    /// which would wait on this lock. The transition comes first so every
    /// `lastInteractedAt` broadcast lands after the snooze is gone.
    ///
    /// If logging throws, a row this call cleared goes back to `.pending`
    /// with its floor; the lock keeps anything else from moving it first.
    /// Then it returns `false` for a notification whose contact isn't
    /// `isCadenceEligible` (a notification can outlive tracking) and
    /// rethrows anything else. A failed reschedule after a logged interaction
    /// still returns `true`; the row stays `.userCaughtUp` until the next run.
    @discardableResult
    public func recordInteraction(contactId: UUID, _ interaction: Interaction) async throws -> Bool {
        await lock()
        defer { unlock() }
        let cadenceId = Self.reminderID(contactId: contactId, kind: .cadence)
        let cleared = try await reminders.transitionState(id: cadenceId, from: .pending, to: .userCaughtUp)
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
            if cleared {
                do {
                    try await reminders.transitionState(id: cadenceId, from: .userCaughtUp, to: .pending)
                } catch {
                    let errorType = String(describing: type(of: error))
                    Self.log.error("couldn't restore a cleared snooze: \(errorType, privacy: .public)")
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
    /// still ahead, so the screen and Overdue agree. `nil` when no snooze is
    /// still ahead (a spent floor can stay on a due row, which the no-re-nag
    /// rule leaves alone). `.max()` so a stray row can't win by fetch order.
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
