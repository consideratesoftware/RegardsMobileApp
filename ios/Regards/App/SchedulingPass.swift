import Foundation

/// The §14 PR22 DB-only stub of `SchedulingPass` (decision #36:
/// "`SchedulingPass` actor is the sole writer of `ScheduledReminder` rows and
/// OS notifications"). This slice's surface is Snooze and the caught-up
/// side effect on any pending cadence row: pushing a contact's cadence
/// reminder 7 days out via a direct `ScheduledReminder` upsert, and
/// transitioning a pending cadence row to `.userCaughtUp` when the contact
/// is marked caught up elsewhere.
///
/// There is no reconciliation, batching, occasion handling, or no-double-up
/// suppression here, no `NotificationScheduling` call, and neither
/// `runFull()` nor the general `run(for contactId:)` from §9a's full
/// contract — TF-07 (PR25) absorbs this type and builds all of that on top
/// of it. Every write below stays inside `ReminderRepository`; nothing here
/// touches `ContactRepository` or `InteractionRepository` (`Caught up` and
/// `Log other` go through `InteractionLogging` instead, which never touches
/// `ScheduledReminder`).
public actor SchedulingPass {
    private let reminders: any ReminderRepository
    private let clock: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        reminders: any ReminderRepository,
        clock: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.reminders = reminders
        self.clock = clock
        self.calendar = calendar
    }

    /// Snooze 1 week (decision #31): pushes the contact's cadence reminder to
    /// fire 7 *calendar* days out; state stays `.pending`. No interaction is
    /// logged and `lastInteractedAt` is never touched — snoozing is not
    /// talking to someone. `calendar.date(byAdding: .day, value: 7, to:)`,
    /// not `addingTimeInterval(7 * 86_400)`: elapsed seconds cross a DST
    /// transition at a different wall-clock time than they started —
    /// exactly the class of bug §19's R1 closed for the engine's own
    /// `nextAllowedSlot` walk, and §9 contract 1 is wall-clock-only for this
    /// stub too. `addingTimeInterval` remains only as the graceful fallback
    /// below for the near-impossible case `byAdding` returns `nil`, mirroring
    /// `UpcomingViewModel.buildRows`' horizon-end fallback: degrade to
    /// elapsed time rather than silently produce no reminder at all.
    ///
    /// Idempotent by re-push, not by stacking: calling this again computes a
    /// fresh `now + 7 days` from *that* call's clock reading, replacing
    /// whatever target the previous snooze set — it does not add 7 more days
    /// on top of an already-snoozed date. Repeated snoozing always means
    /// "one more week from right now."
    ///
    /// §9's full contract resolves `nextAllowedSlot(from: firedAt + 7d, in:
    /// effectiveWindow)` — window- and quiet-hours-aware. This DB-only stub
    /// skips that resolution entirely (no `ReminderWindow`, no
    /// `ReminderEngine` dependency here); PR25 fills it in when
    /// `SchedulingPass` gains its full read/write surface.
    ///
    /// The written row's `id` is deterministic — `cadenceReminderID(contactId:)`,
    /// not a fresh random UUID — specifically so this method has no read
    /// before its write. An earlier version read the existing pending cadence
    /// reminder first to decide whether to update it or insert a new one;
    /// two overlapping calls for the same contact (e.g. tapping Snooze twice
    /// fast, or racing Overdue's and Contact Detail's independent calls)
    /// could both see "nothing pending" before either had written, and both
    /// would then insert under a fresh random id — two pending cadence rows
    /// for one contact, silently disagreeing between screens. A pending
    /// cadence reminder is always exactly this id for this contact, so two
    /// concurrent `upsert`s race the *same* primary key: whichever commits
    /// last simply overwrites the other's row instead of coexisting beside
    /// it. No read, no in-actor lock, no lost update.
    public func snooze(contactId: UUID) async throws {
        let now = clock()
        let scheduledFor = calendar.date(byAdding: .day, value: 7, to: now)
            ?? now.addingTimeInterval(7 * 86_400)
        let reminder = ScheduledReminder(
            id: Self.cadenceReminderID(contactId: contactId),
            contactId: contactId,
            kind: .cadence,
            scheduledFor: scheduledFor,
            osNotificationId: Self.cadenceNotificationId(contactId: contactId),
            state: .pending
        )
        try await reminders.upsert(reminder)
    }

    /// "Caught up" side effect on `SchedulingPass`'s own state (§9's
    /// caught-up re-evaluation trigger: "cancel pending reminder(s) for the
    /// contact/group, reschedule"). Bugfix for a real cross-screen defect
    /// (PR #49 hosted review): `OverdueViewModel`/`UpcomingViewModel` fold a
    /// pending snooze's `scheduledFor` into `max(now, overdueAt,
    /// snoozedUntil)` when computing a row's date. Without this, a
    /// caught-up left the stale snoozed row `.pending`, so that `max(...)`
    /// kept picking the old snoozed date over the freshly-computed one
    /// whenever the cadence was short enough that `overdueAt` (now +
    /// cadence) landed *before* the stale `snoozedUntil` (now + 7d from the
    /// snooze) — invisible whenever the widened-cadence math happened to put
    /// the fresh date later anyway, which is why
    /// `caughtUpAfterSnoozeBeatsStaleSnooze` (cadence 10) passed while this
    /// bug shipped.
    ///
    /// A state *transition*, not a delete: §7's lifecycle keeps a
    /// caught-up-superseded reminder as a `.userCaughtUp` row rather than
    /// removing it, and both `fetchAllPending()`/`fetchPending(forContact:)`
    /// already filter to `state == .pending`, so this is enough on its own
    /// to drop out of every read site's "pending" view — no caller-side
    /// filtering needed.
    ///
    /// Writes to `cadenceReminderID(contactId:)` directly rather than
    /// deciding *whether* to write from a read first: a contact's pending
    /// cadence reminder, if one exists, is always exactly that id (this stub
    /// is the sole writer of cadence rows and never uses any other id), so
    /// there's nothing to look up before writing. `updateState` is a no-op —
    /// not an error — when nothing matches that id, which is exactly the
    /// idempotence this needs: a contact with no pending snooze has nothing
    /// to transition, and calling this twice in a row does nothing the
    /// second time.
    ///
    /// The read before the write (staged review round 7) exists for a
    /// different reason than deciding insert-vs-update: it reports back
    /// *whether a pending row actually existed*, so a caller whose own later
    /// write then fails knows whether this call cleared something worth
    /// restoring. `restorePendingAfterFailedCaughtUp` below is that
    /// compensation; a caller must check this return value before calling
    /// it, since calling it unconditionally after every failure would risk
    /// resurrecting a `.userCaughtUp` row a *different*, already-successful
    /// caught-up left behind (this call's own `updateState` is a no-op
    /// either way, so it can't tell those two cases apart on its own).
    @discardableResult
    public func caughtUp(contactId: UUID) async throws -> Bool {
        let id = Self.cadenceReminderID(contactId: contactId)
        let wasPending = try await reminders.fetchPending(forContact: contactId).contains { $0.id == id }
        try await reminders.updateState(id: id, state: .userCaughtUp)
        return wasPending
    }

    /// Compensates a `caughtUp(contactId:)` whose caller's own later write
    /// then failed (staged review round 7): a failed "Caught up"/"Log other"
    /// used to leave the cleared snooze gone for good — the user heard only
    /// "Couldn't mark X caught up," with no reload restoring the reminder
    /// their earlier Snooze tap had set. Reverts the state transition back
    /// to `.pending`, restoring exactly the row `caughtUp` changed: same id,
    /// same `scheduledFor`. Deliberately not a second `snooze(contactId:)`
    /// call — that would compute a fresh `now + 7d` from this call's own
    /// clock reading, fabricating a date the user never chose, in place of
    /// the one they did.
    ///
    /// Call only when `caughtUp(contactId:)` returned `true` for this same
    /// action. Calling it after a `false` — or after some other action's
    /// `caughtUp` — would blindly set `.pending` on a row this call has no
    /// way to confirm was genuinely this action's to restore.
    public func restorePendingAfterFailedCaughtUp(contactId: UUID) async throws {
        try await reminders.updateState(id: Self.cadenceReminderID(contactId: contactId), state: .pending)
    }

    private static func cadenceNotificationId(contactId: UUID) -> String {
        "contact-\(contactId.uuidString)-\(ReminderKind.cadence.rawValue)"
    }

    /// A contact's cadence `ScheduledReminder` always lives at this id — not
    /// a fresh random one per write. Derived by XORing the contact's own
    /// UUID bytes against a fixed 16-byte salt: deterministic and stable
    /// across launches (unlike `Hasher`, which reseeds per process), with no
    /// need for cryptographic strength since the only goal is "the same
    /// contact always maps to the same row," not collision-resistance
    /// against an adversary.
    ///
    /// PR25: reuse this exact derivation for cadence rows rather than
    /// re-deriving a new scheme, and give occasion rows (birthday,
    /// anniversary, custom) their own distinct derivation — salted
    /// differently, or folded with `ReminderKind` — so a contact's cadence
    /// and occasion ids can never collide. A writer that skips this and goes
    /// back to a fresh random id per write resurrects the exact duplicate-row
    /// race this method exists to close (see `snooze(contactId:)`'s doc
    /// comment above).
    private static func cadenceReminderID(contactId: UUID) -> UUID {
        let salt: [UInt8] = Array("cadence-reminder".utf8.prefix(16))
        var bytes = withUnsafeBytes(of: contactId.uuid) { Array($0) }
        for index in bytes.indices {
            bytes[index] ^= salt[index % salt.count]
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
