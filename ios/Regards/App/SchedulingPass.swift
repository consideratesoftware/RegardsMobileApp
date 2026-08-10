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

    public init(
        reminders: any ReminderRepository,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reminders = reminders
        self.clock = clock
    }

    /// Snooze 1 week (decision #31): pushes the contact's cadence reminder to
    /// fire `now + 7 days`; state stays `.pending`. No interaction is logged
    /// and `lastInteractedAt` is never touched — snoozing is not talking to
    /// someone. `86_400` is exact seconds-per-day, not calendar days — a
    /// snooze that spans a DST transition lands at a wall-clock time 1 hour
    /// off from "the same time, 7 days later." PR25's engine-driven version
    /// (see below) is where that gets fixed; this stub inherits the same
    /// elapsed-time semantics `ReminderEngine.nextAllowedSlot` explicitly
    /// rejects for the real scheduling walk (R1), scoped down here to a
    /// single fixed offset with no window to re-validate against.
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
        let reminder = ScheduledReminder(
            id: Self.cadenceReminderID(contactId: contactId),
            contactId: contactId,
            kind: .cadence,
            scheduledFor: clock().addingTimeInterval(7 * 86_400),
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
    /// Targets `cadenceReminderID(contactId:)` directly rather than reading
    /// first: a contact's pending cadence reminder, if one exists, is always
    /// exactly that id (this stub is the sole writer of cadence rows and
    /// never uses any other id), so there's nothing to look up.
    /// `updateState` is a no-op — not an error — when nothing matches that
    /// id, which is exactly the idempotence this needs: a contact with no
    /// pending snooze has nothing to transition, and calling this twice in a
    /// row does nothing the second time.
    public func caughtUp(contactId: UUID) async throws {
        try await reminders.updateState(id: Self.cadenceReminderID(contactId: contactId), state: .userCaughtUp)
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
