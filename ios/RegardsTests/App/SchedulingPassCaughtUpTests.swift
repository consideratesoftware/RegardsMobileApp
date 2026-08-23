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

    /// R59 regression (staged review round 14). Deterministic, not a hope
    /// that a real race reproduces: `GatedFetchByIDContactRepository` holds
    /// `snooze`'s R54 precondition read open, the test lands a full
    /// `caughtUp` inside that window, then releases it.
    ///
    /// Before the compare-and-set fix, `snooze` resumed and blindly upserted
    /// `.pending` over the `.userCaughtUp` row at the same canonical id,
    /// silently reverting the user's caught-up for seven days. Now the write
    /// is conditional on the state `snooze` observed *before* it suspended,
    /// so the interleaving is rejected: `caughtUp` stands and `snooze`
    /// reports `false`.
    ///
    /// This also pins the ordering inside `snooze` itself, which is subtle
    /// enough to get wrong twice: the state observation has to happen before
    /// the gated contact read. Observing it afterwards makes the CAS agree
    /// with the caught-up it was supposed to detect, and this test fails.
    @Test(
        "A caught-up landing inside snooze's in-flight precondition read is not reverted",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpDuringSnoozeInFlightReadSurvives(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(526), suffix: "r59-interleave", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let openScheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now }
        )
        // A real pending snooze first, so `caughtUp` has a row to transition.
        #expect(try await openScheduler.snooze(contactId: contact.id))
        // Capture the row's id from the repository rather than reaching for
        // `SchedulingPass.cadenceReminderID`, which is private and should
        // stay that way for one assertion's sake.
        let reminderID = try #require(
            await repositories.reminders.fetchPending(forContact: contact.id).first
        ).id

        let gate = AsyncGate()
        let gatedScheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: GatedFetchByIDContactRepository(wrapped: repositories.contacts, gate: gate),
            clock: { now }
        )
        async let racingSnooze: Bool = gatedScheduler.snooze(contactId: contact.id)
        // Only proceed once `snooze` has genuinely reached the gated read.
        await gate.waitUntilArrived()
        #expect(try await openScheduler.caughtUp(contactId: contact.id))
        await gate.open()

        #expect(try await racingSnooze == false)
        #expect(try await repositories.reminders.state(id: reminderID) == .userCaughtUp)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    /// The other half of the same rule, and the reason the fix is a
    /// compare-and-set against the observed state rather than a blanket
    /// "never overwrite `.userCaughtUp`": an *ordinary* snooze taken after a
    /// caught-up has already settled must still succeed. It observes
    /// `.userCaughtUp` itself, so nothing changed under it and the write
    /// goes through. Only interleavings are rejected, never sequences.
    @Test(
        "A snooze taken after a settled caught-up still writes",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeAfterSettledCaughtUpStillWrites(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(527), suffix: "r59-sequence", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now }
        )

        #expect(try await scheduler.snooze(contactId: contact.id))
        #expect(try await scheduler.caughtUp(contactId: contact.id))
        #expect(try await scheduler.snooze(contactId: contact.id))

        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].scheduledFor == now.addingTimeInterval(7 * 86_400))
    }
}
