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
    /// there's nothing to look up before writing. A no-op when nothing
    /// matches — not an error — is exactly the idempotence this needs: a
    /// contact with no pending snooze has nothing to transition, and calling
    /// this twice in a row does nothing the second time.
    ///
    /// `reminders.transitionState(from: .pending, to: .userCaughtUp)`, not a
    /// plain `updateState` — a compare-and-set, not a blind write (staged
    /// review round 8, correcting round 7's fix). Round 7 paired a separate
    /// `fetchPending` read with `updateState` to learn whether a pending row
    /// existed, so a caller whose own later write then failed would know
    /// whether to restore it; that left a window between the read and the
    /// write where two *concurrent* callers for the same contact could both
    /// observe the row as pending and both believe they were the one
    /// responsible for clearing it — so if one succeeded and the other's
    /// later write then failed, the failing caller's restore could re-pend a
    /// snooze the successful caller had legitimately cleared.
    /// `transitionState`'s single atomic statement means only the call that
    /// actually wins the race — the one whose write lands while the row is
    /// still genuinely `.pending` — gets `true` back; the loser sees the row
    /// already `.userCaughtUp` and correctly gets `false`, so it never
    /// attempts a restore that would undo the winner's legitimate success.
    ///
    /// This does not close every case, only the one two truly concurrent
    /// callers can hit: if the row is re-snoozed and then caught up again by
    /// someone else in the narrow gap between this call's own transition and
    /// this same action's *later* restore call (below), that restore would
    /// still revert the newer catch-up, since state alone can't distinguish
    /// "the row this call transitioned" from "a different row some other
    /// caller transitioned to the identical state afterward." Closing that
    /// fully needs a per-write identity this schema doesn't carry — out of
    /// scope for a stub PR25 replaces; the risk window is one failed write
    /// nested inside another action's full round trip, narrower still than
    /// the race this fixes.
    @discardableResult
    public func caughtUp(contactId: UUID) async throws -> Bool {
        try await reminders.transitionState(
            id: Self.cadenceReminderID(contactId: contactId),
            from: .pending,
            to: .userCaughtUp
        )
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
    /// Also a compare-and-set (round 8), `from: .userCaughtUp, to: .pending`
    /// — the mirror image of `caughtUp`'s own transition, and for the same
    /// reason: if something else already moved the row away from
    /// `.userCaughtUp` before this call runs, restoring unconditionally
    /// would clobber whatever that other write left behind instead of
    /// leaving it alone.
    ///
    /// Call only when `caughtUp(contactId:)` returned `true` for this same
    /// action. Calling it after a `false` — or after some other action's
    /// `caughtUp` — would attempt to set `.pending` on a row this call has
    /// no way to confirm was genuinely this action's to restore; the
    /// compare-and-set above prevents that attempt from doing damage, but
    /// the caller-side check stays the first line of defense.
    public func restorePendingAfterFailedCaughtUp(contactId: UUID) async throws {
        try await reminders.transitionState(
            id: Self.cadenceReminderID(contactId: contactId),
            from: .userCaughtUp,
            to: .pending
        )
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
    /// The fixed `bytes[0]`...`bytes[15]` indexing below relies on
    /// `contactId.uuid` (`uuid_t`) always unpacking to exactly 16 bytes
    /// (nit, staged review round 8) — unstated in code, but not a guess:
    /// `uuid_t` is Foundation's fixed 16-`UInt8` tuple mirroring RFC 4122's
    /// 128-bit UUID layout, and `withUnsafeBytes(of:)` over a fixed-size C
    /// tuple always yields a buffer of that tuple's exact byte width, so
    /// `bytes.count` is always 16 here — never a source of out-of-bounds
    /// indexing to guard against at runtime.
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
