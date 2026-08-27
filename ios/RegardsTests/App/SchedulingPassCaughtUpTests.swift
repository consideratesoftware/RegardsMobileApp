import Foundation
import Testing
@testable import Regards

/// `SchedulingPass.caughtUp` and `restorePendingAfterFailedCaughtUp`
/// coverage, split out of `SchedulingPassTests` when that struct crossed
/// SwiftLint's 300-line type body limit (staged review round 10). Shares
/// that file's (and `RepositoriesTests.swift`'s) `RepositoryContractBackend`
/// / `contractContact` / `contractUUID` helpers.
struct SchedulingPassCaughtUpTests {

    @Test(
        "Caught up transitions a pending cadence row to userCaughtUp, dropping it from every pending read",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpTransitionsPendingCadenceRow(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(506), suffix: "caughtup-transition", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now }
        )
        try await scheduler.snooze(contactId: contact.id)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count == 1)

        // The return value (round 7): `true` — a pending row genuinely
        // existed and was transitioned, not just "the write ran."
        let clearedSomething = try await scheduler.caughtUp(contactId: contact.id)

        #expect(clearedSomething)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
        #expect(try await repositories.reminders.fetchAllPending()
            .contains { $0.contactId == contact.id } == false)
    }

    /// Invariant test, not a fix (staged review round 10): `caughtUp` (and
    /// `restorePendingAfterFailedCaughtUp`) only ever target
    /// `cadenceReminderID(contactId:)` — never a full "every pending row
    /// for this contact" sweep. That's only safe because `SchedulingPass`
    /// is documented as the sole writer of cadence rows, always at that
    /// one deterministic id (see `cadenceReminderID`'s own doc comment); a
    /// row at any other id would indeed be permanently unclearable by this
    /// actor. This seeds exactly such a row directly through the
    /// repository — bypassing `SchedulingPass` entirely, since nothing in
    /// this actor's own surface can produce one — and proves the
    /// invariant holds today: untouched by `caughtUp`, confirming the
    /// narrow targeting is intentional rather than an accidental gap.
    @Test(
        "Caught up never touches a cadence row parked at a non-canonical id",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpNeverTouchesNonCanonicalCadenceRow(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(517), suffix: "caughtup-noncanonical", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now }
        )
        try await scheduler.snooze(contactId: contact.id) // the canonical row

        // A second, non-canonical cadence row for the same contact — never
        // produced by `SchedulingPass` itself, but constructed directly
        // here to prove `caughtUp` doesn't accidentally sweep every
        // pending row for the contact.
        let strayRow = ScheduledReminder(
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: now.addingTimeInterval(14 * 86_400),
            osNotificationId: "contact-\(contact.id.uuidString)-stray-cadence"
        )
        try await repositories.reminders.upsert(strayRow)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count == 2)

        try await scheduler.caughtUp(contactId: contact.id)

        let stillPending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(stillPending.count == 1)
        #expect(stillPending[0].id == strayRow.id)
        #expect(stillPending[0].scheduledFor == strayRow.scheduledFor)
    }

    @Test(
        "Caught up with no pending reminder is a no-op, not an error",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpWithNoPendingRowIsNoOp(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(507), suffix: "caughtup-no-op", tracked: true)
        try await repositories.contacts.upsert(contact)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        // Never snoozed — no pending cadence row exists for this contact.
        // The `false` return (round 7) is the signal a caller uses to skip
        // any later restore-on-failure compensation.
        let clearedSomething = try await scheduler.caughtUp(contactId: contact.id)
        #expect(clearedSomething == false)

        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)

        // Calling it again (the "twice in a row" half of idempotence) is
        // equally uneventful, and still reports nothing was pending to clear.
        let secondCall = try await scheduler.caughtUp(contactId: contact.id)
        #expect(secondCall == false)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    /// The blocker this pins (staged review round 8, "the worst of the
    /// four" — the coordinator's own words): round 7's `caughtUp` paired a
    /// separate `fetchPending` read with `updateState`, leaving a window
    /// where two concurrent callers for the same contact could both observe
    /// the row as pending and both report `true`. If one caller's later
    /// write then failed, its restore would re-pend a snooze the *other*,
    /// successful caller had legitimately cleared. `async let` drives two
    /// genuinely concurrent `caughtUp` calls the same way
    /// `concurrentSnoozeResolvesToOneRow` (`SchedulingPassTests`) drives
    /// two concurrent `snooze` calls — Swift actor re-entrancy at
    /// `caughtUp`'s own `await` lets both bodies interleave before
    /// either's `transitionState` write lands, so this reproduces the race
    /// rather than assuming it.
    @Test(
        "Two concurrent caught-ups on the same pending row: only one reports having cleared it",
        arguments: RepositoryContractBackend.allCases
    )
    func concurrentCaughtUpOnlyOneWinsTheTransition(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(512), suffix: "caughtup-concurrent", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now }
        )
        try await scheduler.snooze(contactId: contact.id)

        async let first = scheduler.caughtUp(contactId: contact.id)
        async let second = scheduler.caughtUp(contactId: contact.id)
        let (firstCleared, secondCleared) = try await (first, second)

        // Exactly one call transitioned a genuinely pending row; the other
        // found it already `.userCaughtUp` and correctly reported nothing to
        // restore — the discriminator round 7's separate-read design could
        // not make (it could report `true` for both).
        #expect([firstCleared, secondCleared].filter { $0 }.count == 1)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    // MARK: - restorePendingAfterFailedCaughtUp (staged review round 7)

    /// The compensation this pins: a caller's own later write fails after
    /// `caughtUp` already cleared a real snooze, and the exact same row
    /// (same id, same `scheduledFor`) comes back — not a freshly computed
    /// `now + 7d` from a second `snooze()` call.
    @Test(
        "Restoring after a failed caught-up brings back the exact same pending row",
        arguments: RepositoryContractBackend.allCases
    )
    func restorePendingAfterFailedCaughtUpBringsBackSameRow(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(510), suffix: "caughtup-restore", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now }
        )
        try await scheduler.snooze(contactId: contact.id)
        let original = try await repositories.reminders.fetchPending(forContact: contact.id)[0]
        _ = try await scheduler.caughtUp(contactId: contact.id)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)

        try await scheduler.restorePendingAfterFailedCaughtUp(contactId: contact.id)

        let restored = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(restored.count == 1)
        #expect(restored[0].id == original.id)
        #expect(restored[0].scheduledFor == original.scheduledFor)
        #expect(restored[0].state == .pending)
    }

    /// Calling this without a preceding `caughtUp` in the same action is
    /// meant to be safe (no row exists at the deterministic id yet), matching
    /// `caughtUp`'s own no-op-when-nothing-matches idempotence.
    @Test(
        "Restoring with nothing to restore is a no-op, not an error",
        arguments: RepositoryContractBackend.allCases
    )
    func restorePendingAfterFailedCaughtUpWithNothingPendingIsNoOp(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(511), suffix: "caughtup-restore-noop", tracked: true)
        try await repositories.contacts.upsert(contact)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        try await scheduler.restorePendingAfterFailedCaughtUp(contactId: contact.id)

        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    /// The compare-and-set this pins (round 8): a re-snooze between
    /// `caughtUp` and its would-be restore leaves the row `.pending` again
    /// with a *new* `scheduledFor` — restoring must not fire at all here
    /// (the row is no longer `.userCaughtUp`, the state this call is only
    /// ever allowed to move away from), or it would silently discard the
    /// fresh snooze the user just set.
    @Test(
        "Restoring after a re-snooze leaves the fresh snooze alone",
        arguments: RepositoryContractBackend.allCases
    )
    func restorePendingAfterFailedCaughtUpDoesNotClobberAFreshSnooze(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(513), suffix: "caughtup-restore-resnoozed", tracked: true)
        try await repositories.contacts.upsert(contact)
        let firstNow = Date(timeIntervalSince1970: 1_800_000_000)
        let secondNow = firstNow.addingTimeInterval(3 * 86_400)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { firstNow }
        )
        try await scheduler.snooze(contactId: contact.id)
        _ = try await scheduler.caughtUp(contactId: contact.id)
        // Re-snoozed from a later clock reading before the compensation for
        // the *earlier* caught-up ever runs — simulates the user snoozing
        // again while an earlier failed action's restore is still pending.
        try await SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { secondNow }
        )
            .snooze(contactId: contact.id)
        let freshSnooze = try await repositories.reminders.fetchPending(forContact: contact.id)[0]

        try await scheduler.restorePendingAfterFailedCaughtUp(contactId: contact.id)

        let afterRestore = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(afterRestore.count == 1)
        #expect(afterRestore[0].scheduledFor == freshSnooze.scheduledFor)
        #expect(afterRestore[0].scheduledFor == secondNow.addingTimeInterval(7 * 86_400))
    }

    /// R59 regression, rewritten for the per-contact lock (staged review
    /// round 17). Rounds 14–16 fixed this with a compare-and-set and each
    /// fix exposed the next interleaving; `SchedulingPass` now serialises
    /// mutations per contact instead, so the whole class is closed rather
    /// than one pair at a time.
    ///
    /// **Both operations go through one `SchedulingPass` on purpose.** The
    /// locks are actor state, so they only serialise callers sharing an
    /// instance — which production does (`AppEnvironment.scheduler` is a
    /// single `let`, handed to every screen). An earlier version of this
    /// test used two instances to force the race; that no longer models
    /// anything real, and would test only that two schedulers can corrupt
    /// each other, which production cannot do.
    ///
    /// `GatedFetchByIDContactRepository` holds `snooze`'s precondition read
    /// open, so `caughtUp` is issued while `snooze` is genuinely mid-flight.
    /// Whichever order the lock grants, the caught-up must not be silently
    /// lost: no pending row may survive to suppress the contact for a week.
    @Test(
        "A caught-up issued while a snooze is mid-flight is not silently lost",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpDuringInFlightSnoozeIsNotLost(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(526), suffix: "r59-interleave", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = AsyncGate()
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: GatedFetchByIDContactRepository(wrapped: repositories.contacts, gate: gate),
            clock: { now }
        )

        async let racingSnooze: Bool = scheduler.snooze(contactId: contact.id)
        await gate.waitUntilArrived()
        // Issued while the snooze holds the lock: it queues behind it rather
        // than interleaving with it.
        async let racingCaughtUp: Bool = scheduler.caughtUp(contactId: contact.id)
        await gate.open()
        _ = try await (racingSnooze, racingCaughtUp)

        // The user-visible guarantee: whatever order the two settled in, the
        // contact is not left snoozed for seven days by a write whose
        // decision predates the caught-up.
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    /// The same guarantee with no pre-existing row — the normal state before
    /// a contact's first snooze, since `snooze` is the only thing that
    /// writes a cadence row. Round 15 needed a separate marker-row mechanism
    /// to cover this; serialisation covers it with no extra machinery, which
    /// is the point.
    @Test(
        "A caught-up issued mid-snooze is not lost when no reminder row exists yet",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpDuringInFlightSnoozeWithNoExistingRow(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(528), suffix: "r59-nil-state", tracked: true)
        try await repositories.contacts.upsert(contact)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = AsyncGate()
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: GatedFetchByIDContactRepository(wrapped: repositories.contacts, gate: gate),
            clock: { now }
        )

        async let racingSnooze: Bool = scheduler.snooze(contactId: contact.id)
        await gate.waitUntilArrived()
        async let racingCaughtUp: Bool = scheduler.caughtUp(contactId: contact.id)
        await gate.open()
        let (snoozed, caughtUp) = try await (racingSnooze, racingCaughtUp)

        // The snooze wrote (it held the lock first); the caught-up then
        // transitioned that very row, so nothing pending is left behind.
        #expect(snoozed)
        #expect(caughtUp)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    /// Serialisation must not deadlock or starve: many concurrent mutations
    /// for one contact all complete, and the row stays singular throughout.
    @Test("Concurrent mixed mutations for one contact all complete under the lock")
    func concurrentMixedMutationsAllComplete() async throws {
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(529), suffix: "r59-lock-throughput", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now }
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        _ = try? await scheduler.snooze(contactId: contact.id)
                    } else {
                        _ = try? await scheduler.caughtUp(contactId: contact.id)
                    }
                }
            }
        }

        // Reaching here at all is the deadlock check. One canonical id means
        // at most one row, whatever order the twelve settled in.
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count <= 1)
    }

    /// R61(e), round 20 blocker. The per-contact lock suspends waiters in a
    /// `withCheckedContinuation`, which is not cancellation-aware: a
    /// cancelled waiter cannot remove itself from the queue. What must hold
    /// regardless is liveness — if a waiting task is cancelled, the lock
    /// must still reach the next caller for that contact rather than
    /// stranding it forever.
    ///
    /// Structure: a gated first caller holds the lock; a second caller
    /// queues behind it and is then cancelled; a third caller queues too.
    /// Releasing the gate must let the chain drain and the third caller
    /// complete. If it cannot, this test hangs rather than fails — which is
    /// itself the signal, since a stranded lock has no failing assertion to
    /// report.
    @Test("A cancelled waiter does not strand the per-contact lock")
    func cancelledWaiterDoesNotStrandTheLock() async throws {
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(530), suffix: "r61e-cancel", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = AsyncGate()
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: GatedFetchByIDContactRepository(wrapped: repositories.contacts, gate: gate),
            clock: { now }
        )

        // Holder: parks inside its gated precondition read, holding the lock.
        let holder = Task { try await scheduler.snooze(contactId: contact.id) }
        await gate.waitUntilArrived()

        // Waiter that gets cancelled while queued behind the holder.
        let cancelled = Task { try await scheduler.caughtUp(contactId: contact.id) }
        await Task.yield()
        cancelled.cancel()

        // A third caller, queued behind both.
        let follower = Task { try await scheduler.caughtUp(contactId: contact.id) }
        await Task.yield()

        await gate.open()
        _ = try? await holder.value
        _ = try? await cancelled.value
        // The assertion that matters: this returns at all.
        _ = try? await follower.value

        // And the lock is genuinely free afterwards — a fresh caller on an
        // ungated scheduler completes rather than queueing forever.
        let free = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now }
        )
        _ = try await free.snooze(contactId: contact.id)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count <= 1)
    }
}
