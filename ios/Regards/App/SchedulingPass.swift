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
/// of it. `Caught up` and `Log other` go through `InteractionLogging`
/// instead, which never touches `ScheduledReminder`.
///
/// Does read `ContactRepository`, despite the "DB-only, `ReminderRepository`
/// only" framing above (R54, staged review): `snooze(contactId:)` needs to
/// know a contact is `tracked` with a `cadenceDays` set before it writes,
/// and that precondition has to live here, not only at the callers that
/// happen to exist today. `OverdueViewModel.snooze` offers
/// Snooze only for a row already computed as overdue, which requires
/// `tracked && cadenceDays != nil` by construction.
/// `ContactDetailViewModel.snooze` does **not**: that screen gates its
/// Snooze button on `tracked && cadenceDays != nil` directly and says
/// nothing about overdue-ness, so the precondition is reachable there and is
/// not the dead code an earlier version of this comment claimed (staged
/// review round 14 — the claim was load-bearing for R54's stated rationale,
/// so it is corrected rather than dropped). Separately,
/// `ContactDetailViewModel.snooze()` is `public` and ungated beyond an
/// `isActive` check; a future caller reaching it some other way (a
/// notification action invoking the view model directly, say) would still
/// write an orphaned pending reminder no `fetchTracked()`-backed screen
/// (Overdue, Upcoming) will ever surface. Guarding the two callers this
/// stub happens to know about is exactly what left the hole open the first
/// two times (R54's own original note); closing it in the one place every
/// caller — known or future — must pass through is what actually closes it.
public actor SchedulingPass {
    private let reminders: any ReminderRepository
    private let contacts: any ContactRepository
    private let clock: @Sendable () -> Date
    private let calendar: Calendar

    /// Contacts with a mutation in flight, and who is queued behind them.
    ///
    /// **Why this exists (R59, staged review rounds 13–17).** Every mutation
    /// here suspends partway through — a repository read, then a write — and
    /// an actor permits reentrancy at every suspension. Four consecutive
    /// review rounds found a different pair of operations interleaving at
    /// one of those points: a `caughtUp` landing inside `snooze`'s
    /// precondition read and being overwritten; the same with no row yet
    /// written; a losing `snooze` reporting failure; and the mirror, a
    /// `caughtUp` losing to a `snooze` that committed first. Each was closed
    /// with a narrower compare-and-set, and each fix exposed the next pair.
    /// Serialising per contact closes the class instead of the instance: no
    /// two mutations for one contact overlap, so no decision made before a
    /// suspension can be applied after someone else's write.
    ///
    /// **Load-bearing premise: one instance.** These locks are actor state,
    /// so they only serialise callers sharing this `SchedulingPass`.
    /// `AppEnvironment` holds exactly one (`public let scheduler`) and every
    /// screen is handed that same one. Constructing a second in production
    /// would silently void the guarantee without failing anything.
    private var busyContacts: Set<UUID> = []
    private var lockWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    /// Suspends until no other mutation for `contactId` is in flight.
    /// Always pair with `unlock` via `defer`.
    private func lock(_ contactId: UUID) async {
        if busyContacts.contains(contactId) {
            await withCheckedContinuation { continuation in
                lockWaiters[contactId, default: []].append(continuation)
            }
            // Resumed by `unlock`, which hands the lock over directly rather
            // than releasing it — so it is still held on our behalf here,
            // and no third caller can slip in between.
            return
        }
        busyContacts.insert(contactId)
    }

    private func unlock(_ contactId: UUID) {
        guard var queue = lockWaiters[contactId], !queue.isEmpty else {
            busyContacts.remove(contactId)
            return
        }
        let next = queue.removeFirst()
        lockWaiters[contactId] = queue.isEmpty ? nil : queue
        // Hand off without clearing `busyContacts`: the resumed waiter owns
        // the lock immediately.
        next.resume()
    }

    public init(
        reminders: any ReminderRepository,
        contacts: any ContactRepository,
        clock: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.reminders = reminders
        self.contacts = contacts
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
    /// not a fresh random UUID — specifically so the *write itself* has no
    /// read before it, only the precondition check below does (added R54,
    /// see this type's own doc comment for why it lives here). An earlier
    /// version read the existing pending cadence reminder first to decide
    /// whether to update it or insert a new one; two overlapping calls for
    /// the same contact (e.g. tapping Snooze twice fast, or racing
    /// Overdue's and Contact Detail's independent calls) could both see
    /// "nothing pending" before either had written, and both would then
    /// insert under a fresh random id — two pending cadence rows for one
    /// contact, silently disagreeing between screens. A pending cadence
    /// reminder is always exactly this id for this contact, so two
    /// concurrent `upsert`s race the *same* primary key: whichever commits
    /// last simply overwrites the other's row instead of coexisting beside
    /// it. No in-actor lock, no lost update *between two snoozes* — the
    /// precondition read above doesn't change that, since it never informs
    /// *which* id the write below uses, only *whether* it happens at all.
    ///
    /// That scoping is deliberate: the claim covers snooze-vs-snooze only.
    /// Snooze-vs-`caughtUp` is a different problem, closed by the
    /// per-contact lock this method takes — not by anything in the write
    /// itself. See §19 R59 for how that was arrived at over four review
    /// rounds; the invariant a reader needs here is just that no other
    /// mutation for this contact can run between the read below and the
    /// write, so the write cannot apply a decision someone else has since
    /// invalidated.
    ///
    /// Returns whether it actually wrote (R54): `false` for an untracked or
    /// no-cadence contact — a rejection, not a silent no-op a caller could
    /// mistake for success, the same shape as
    /// `ContactRepository.updateLastInteractedAt`'s own `Bool` return for
    /// its own precondition failure. A failed contact read is treated as
    /// ineligible, the same conservative default `ContactDetailViewModel
    /// .snooze()`'s own fresh-fetch guard already uses for the identical
    /// situation.
    ///
    /// `contact.isActive` is checked here too, not only tracked/cadence —
    /// slightly wider than R54's own wording ("the tracked/cadence
    /// precondition"), added because the contact is already in hand at
    /// this point and the cost of checking one more field on it is zero.
    /// Both shipped callers already re-fetch and check `isActive`
    /// themselves before ever reaching this write, so this is a genuine
    /// no-op for them today — it only matters for the same class of future
    /// caller R54 is about, which this write-site guard exists to not have
    /// to trust.
    @discardableResult
    public func snooze(contactId: UUID) async throws -> Bool {
        await lock(contactId)
        defer { unlock(contactId) }
        guard let contact = try? await contacts.fetch(id: contactId),
              contact.isActive, contact.tracked, contact.cadenceDays != nil else {
            return false
        }
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
        // A plain upsert again, deliberately. Rounds 14–16 made this a
        // compare-and-set against state observed before the suspension
        // above; the lock makes that redundant, because nothing else can
        // touch this contact's row between the read and this write. The CAS
        // also cost two blockers of its own — a lost race reported as a
        // failed snooze, and a read-back that could not tell a racing snooze
        // from `restorePendingAfterFailedCaughtUp`. Simpler is now also
        // safer; do not reintroduce the conditional write without first
        // removing the lock.
        try await reminders.upsert(reminder)
        return true
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
        await lock(contactId)
        defer { unlock(contactId) }
        // A bare transition, deliberately: this method has no
        // tracked/cadence/`isActive` precondition, so anything here that
        // *inserts* rather than transitions can write an orphan `.cadence`
        // row for an untracked or archived contact. An earlier revision did
        // exactly that (§19 R59).
        return try await reminders.transitionState(
            id: Self.cadenceReminderID(contactId: contactId),
            from: .pending,
            to: .userCaughtUp
        )
    }

    /// The contact's pending cadence reminder's `scheduledFor`, if one
    /// exists — Snooze's only persisted trace (see `snooze(contactId:)`'s
    /// doc comment). `nil` when nothing is pending: never snoozed, a snooze
    /// already lapsed, or `caughtUp(contactId:)` cleared it.
    ///
    /// Read-only counterpart added for R56 (ARCHITECTURE.md): a caller with
    /// no `ReminderRepository` of its own —
    /// `ContactDetailViewModel.overdueSummary` — needs to fold a pending
    /// snooze into its own date math the same way
    /// `OverdueViewModel.makeOverdueRow`/`UpcomingViewModel.buildRows`
    /// already do. Routing the read through this actor rather than handing
    /// out `reminders` directly, or threading a fresh `ReminderRepository`
    /// through every `ContactDetailViewModel` call site, keeps this a
    /// narrow, targeted read instead of widening that view model's
    /// dependency surface — the wider wiring TF-07/PR25 brings can still
    /// replace this later without every call site changing shape again.
    ///
    /// `.max()` over every pending cadence row's `scheduledFor`, not
    /// `.first` (staged review round 11 fix): `fetchPending` orders by
    /// `scheduledFor` ascending, so `.first` picked the *earliest* pending
    /// cadence row, not the one that actually governs. `SchedulingPass`
    /// itself only ever keeps one cadence row per contact (the
    /// deterministic `cadenceReminderID`), but a second, non-canonical row
    /// can reach the table some other way —
    /// `SchedulingPassCaughtUpTests.caughtUpNeverTouchesNonCanonicalCadenceRow`
    /// proves exactly that shape survives `caughtUp` untouched. Matches
    /// `OverdueViewModel.makeOverdueRow`/`UpcomingViewModel.buildRows`'s own
    /// `max($0, $1)` tie-break — the same "picking by array order would make
    /// the winner depend on fetch ordering rather than on which row is
    /// actually later" reasoning applies here, not just there.
    public func pendingSnoozeDate(contactId: UUID) async throws -> Date? {
        try await reminders.fetchPending(forContact: contactId)
            .filter { $0.kind == .cadence }
            .map(\.scheduledFor)
            .max()
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
        // Serialised for the same reason: this writes `.pending` at the very
        // id `snooze` and `caughtUp` contend over.
        await lock(contactId)
        defer { unlock(contactId) }
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
