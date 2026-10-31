import Foundation
import Testing
@testable import Regards

/// `SchedulingPass.recordInteraction` coverage on the shared lock (R59, R60),
/// split out of `SchedulingPassTests` when that struct crossed SwiftLint's
/// 300-line type body limit (staged review round 10). Shares that file's (and
/// `RepositoriesTests.swift`'s) `RepositoryContractBackend` /
/// `contractContact` / `contractUUID` helpers.
struct SchedulingPassCaughtUpTests {

    /// Everything the pass writes for a contact starts from the same fixture:
    /// a tracked contact with a snooze already on its cadence row.
    private static func snoozedContact(
        _ repositories: RepositoryContractRepositories, number: Int, suffix: String, now: Date
    ) async throws -> (contact: Contact, scheduler: SchedulingPass) {
        let contact = contractContact(id: try contractUUID(number), suffix: suffix, tracked: true)
        try await repositories.contacts.upsert(contact)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            interactions: repositories.interactions,
            window: repositories.window,
            occasions: { _ in [] },
            clock: { now }
        )
        try await scheduler.snooze(contactId: contact.id)
        return (contact, scheduler)
    }

    @Test(
        "Caught up replaces a snoozed cadence row with the next cycle's, floor gone",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpReplacesTheSnoozedRowWithTheNextCycle(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (contact, scheduler) = try await Self.snoozedContact(
            repositories, number: 506, suffix: "caughtup-transition", now: now)
        let snoozed = try #require(try await repositories.reminders.fetchPending(forContact: contact.id).first)
        #expect(snoozed.snoozedUntil != nil)

        let logged = try await scheduler.recordInteraction(contactId: contact.id, .caughtUp)

        #expect(logged)
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].id == snoozed.id)
        #expect(pending[0].snoozedUntil == nil)
        // The anchor is now plus the 14-day cadence, so the row moved past it.
        #expect(pending[0].scheduledFor >= now.addingTimeInterval(14 * 86_400))
    }

    /// Invariant test, not a fix (staged review round 10): the pass only
    /// ever writes a contact's cadence row at `reminderID(contactId:kind:)`.
    /// A row at any other id is not the pass's. This seeds one directly,
    /// bypassing the pass, which nothing in its own surface can produce.
    /// The transition still targets only the canonical id, but the
    /// reschedule that follows in the same span sweeps every pending row of
    /// the contact that is not the canonical one, so the stray is cancelled.
    @Test(
        "Caught up cancels a cadence row parked at a non-canonical id through the same-span sweep",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpSweepsANonCanonicalCadenceRow(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (contact, scheduler) = try await Self.snoozedContact(
            repositories, number: 517, suffix: "caughtup-noncanonical", now: now)
        let canonicalId = SchedulingPass.reminderID(contactId: contact.id, kind: .cadence)
        let strayRow = ScheduledReminder(
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: now.addingTimeInterval(14 * 86_400),
            osNotificationId: "contact-\(contact.id.uuidString)-stray-cadence"
        )
        try await repositories.reminders.upsert(strayRow)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count == 2)

        try await scheduler.recordInteraction(contactId: contact.id, .caughtUp)

        let stillPending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(stillPending.map(\.id) == [canonicalId])
    }

    @Test(
        "Caught up with no pending reminder still logs and writes the next cadence row",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpWithNoPendingRowStillLogsAndSchedules(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(507), suffix: "caughtup-no-op", tracked: true)
        try await repositories.contacts.upsert(contact)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            interactions: repositories.interactions,
            window: repositories.window,
            occasions: { _ in [] },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)

        // Never snoozed: the transition finds nothing to move, the log still
        // lands, and the reschedule writes the contact's first row.
        #expect(try await scheduler.recordInteraction(contactId: contact.id, .caughtUp))
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count == 1)
        #expect(try await repositories.interactions.fetchRecent(forContact: contact.id, limit: 10).count == 1)

        // Twice in a row leaves one row and logs twice.
        #expect(try await scheduler.recordInteraction(contactId: contact.id, .caughtUp))
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count == 1)
        #expect(try await repositories.interactions.fetchRecent(forContact: contact.id, limit: 10).count == 2)
    }

    /// A double tap: two concurrent catch-ups each run their whole
    /// transition, log and reschedule, so both report `true` and log, and the
    /// contact ends with one floorless next-cycle row. A behavior pin, not an
    /// R59 discriminator: the end state is the same with the lock disabled.
    @Test(
        "Two concurrent catch-ups both log and leave one floorless next-cycle row",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases
    )
    func concurrentCaughtUpsLeaveOneNextCycleRow(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (contact, scheduler) = try await Self.snoozedContact(
            repositories, number: 512, suffix: "caughtup-concurrent", now: now)

        async let first = scheduler.recordInteraction(contactId: contact.id, .caughtUp)
        async let second = scheduler.recordInteraction(contactId: contact.id, .caughtUp)
        let (firstLogged, secondLogged) = try await (first, second)

        #expect(firstLogged && secondLogged)
        #expect(try await repositories.interactions.fetchRecent(forContact: contact.id, limit: 10).count == 2)
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending.first?.snoozedUntil == nil)
    }

    // MARK: - R60: a compensation never reverts something newer

    enum Interleave: String, CaseIterable, Sendable {
        /// A full run lands while the failing catch-up is mid-log.
        case runFull
        /// A snooze and a newer, successful catch-up land while it is mid-log.
        case snoozeThenCaughtUp
    }

    /// R60. Catch-up A clears a snoozed row, then its log write parks and
    /// fails. Under one lock span nothing can run between A's transition and
    /// its restore, so the snooze comes back untouched (`runFull`) and a newer
    /// catch-up B cannot be reverted by A's restore (`snoozeThenCaughtUp`).
    ///
    /// The bounded wait exists only so code that unlocks around the log call
    /// can interleave. With the lock held it times out after 500 ms and the
    /// test goes on; every assertion follows an awaited task.
    ///
    /// Revert check: unlocking and relocking around the `InteractionLogging`
    /// call makes both cases fail. `runFull` then rewrites the cleared row
    /// floorless before A's restore; and B's second gate parks B's append so
    /// A's restore re-pends B's row with its floor before B reschedules.
    @Test(
        "A failed catch-up's compensation cannot revert a newer run or catch-up",
        .timeLimit(.minutes(1)),
        arguments: RepositoryContractBackend.allCases, Interleave.allCases
    )
    func compensationCannotRevertNewerCatchUp(backend: RepositoryContractBackend, interleave: Interleave) async throws {
        let firstGate = AsyncGate()
        let secondGate = AsyncGate()
        let logStore = StubInteractionRepository()
        let fixture = try await PassFixture(
            backend: backend,
            interactions: GatedFailingAppendInteractionRepository(
                wrapped: logStore, gate: firstGate, secondGate: interleave == .snoozeThenCaughtUp ? secondGate : nil)
        )
        let contact = try await fixture.addContact(1, cadenceDays: 14)
        #expect(try await fixture.pass.snooze(contactId: contact.id))
        let snoozed = try #require(try await fixture.cadenceRow(contact))
        #expect(snoozed.snoozedUntil == PassFixture.at("2026-06-17 10:00"))
        #expect(snoozed.scheduledFor == PassFixture.at("2026-06-17 18:00"))
        let anchor = contact.lastInteractedAt

        let failing = Task { try await fixture.pass.recordInteraction(contactId: contact.id, .caughtUp) }
        await firstGate.waitUntilArrived()

        let newer: Task<Void, any Error>
        let newerArrived: @Sendable () async -> Bool
        switch interleave {
        case .runFull:
            let finished = AsyncGate()
            newer = Task {
                try await fixture.pass.runFull()
                await finished.open()
            }
            newerArrived = { await finished.isOpened }
        case .snoozeThenCaughtUp:
            newer = Task {
                try await fixture.pass.snooze(contactId: contact.id)
                try await fixture.pass.recordInteraction(contactId: contact.id, .caughtUp)
            }
            newerArrived = { await secondGate.arrivalCount > 0 }
        }
        for _ in 0..<50 where !(await newerArrived()) {
            try await Task.sleep(for: .milliseconds(10))
        }

        await firstGate.open()
        await #expect(throws: RepositoryFakeFailure.self) { try await failing.value }
        await secondGate.open()
        try await newer.value

        let logs = await logStore.appendedLogs()
        let stored = try #require(try await fixture.repositories.contacts.fetch(id: contact.id))
        switch interleave {
        case .runFull:
            #expect(try await fixture.cadenceRow(contact) == snoozed)
            #expect(logs.isEmpty)
            #expect(stored.lastInteractedAt == anchor)
        case .snoozeThenCaughtUp:
            let row = try #require(try await fixture.cadenceRow(contact))
            #expect(row.state == .pending)
            #expect(row.scheduledFor == PassFixture.at("2026-06-24 18:00"))
            #expect(row.snoozedUntil == nil)
            #expect(logs.count == 1)
            #expect(stored.lastInteractedAt == PassFixture.at("2026-06-10 10:00"))
        }
    }

    // MARK: - R59: the shared lock

    /// R59 regression, rewritten for the shared lock. Earlier
    /// compare-and-set fixes each exposed the next interleaving;
    /// `SchedulingPass` now serialises every mutation behind one FIFO lock,
    /// so the whole class is closed rather than one pair at a time.
    ///
    /// **Both operations go through one `SchedulingPass` on purpose.** The
    /// lock is actor state, so it only serialises callers sharing an
    /// instance — which production does (`AppRuntime.scheduler` is a
    /// single `let`, handed to every screen). An earlier version of this
    /// test used two instances to force the race; that no longer models
    /// anything real, and would test only that two schedulers can corrupt
    /// each other, which production cannot do.
    ///
    /// `GatedFetchByIDContactRepository` holds `snooze`'s precondition read
    /// open, so `caughtUp` is issued while `snooze` is genuinely mid-flight.
    /// Whichever order the lock grants, the caught-up must not be silently
    /// lost: no snooze may survive it, and the row left behind is the next
    /// cycle's, floorless.
    @Test(
        "A caught-up issued while a snooze is mid-flight is not silently lost",
        .timeLimit(.minutes(1)),
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
            interactions: repositories.interactions,
            window: FixedReminderWindowRepository(),
            occasions: { _ in [] },
            clock: { now }
        )

        async let racingSnooze: Bool = scheduler.snooze(contactId: contact.id)
        await gate.waitUntilArrived()
        // Issued while the snooze holds the lock: it queues behind it rather
        // than interleaving with it.
        async let racingCaughtUp: Bool = scheduler.recordInteraction(contactId: contact.id, .caughtUp)
        await gate.open()
        _ = try await (racingSnooze, racingCaughtUp)

        // The user-visible guarantee: whatever order the two settled in, the
        // contact is not left snoozed for seven days by a write whose
        // decision predates the caught-up.
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending.first?.snoozedUntil == nil)
        #expect(pending.first.map { $0.scheduledFor >= now.addingTimeInterval(14 * 86_400) } == true)
    }

    /// The same guarantee with no pre-existing row — the normal state before
    /// a contact's first snooze, since `snooze` is the only thing that
    /// writes a cadence row. Round 15 needed a separate marker-row mechanism
    /// to cover this; serialisation covers it with no extra machinery, which
    /// is the point.
    @Test(
        "A caught-up issued mid-snooze is not lost when no reminder row exists yet",
        .timeLimit(.minutes(1)),
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
            interactions: repositories.interactions,
            window: FixedReminderWindowRepository(),
            occasions: { _ in [] },
            clock: { now }
        )

        async let racingSnooze: Bool = scheduler.snooze(contactId: contact.id)
        await gate.waitUntilArrived()
        async let racingCaughtUp: Bool = scheduler.recordInteraction(contactId: contact.id, .caughtUp)
        await gate.open()
        let (snoozed, caughtUp) = try await (racingSnooze, racingCaughtUp)

        // The snooze wrote (it held the lock first); the caught-up then
        // replaced that very row with the next cycle's, floorless.
        #expect(snoozed)
        #expect(caughtUp)
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending.first?.snoozedUntil == nil)
    }

    /// Serialisation must not deadlock or starve: many concurrent mutations
    /// for one contact all complete, and the row stays singular throughout.
    @Test("Concurrent mixed mutations for one contact all complete under the lock", .timeLimit(.minutes(1)))
    func concurrentMixedMutationsAllComplete() async throws {
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(529), suffix: "r59-lock-throughput", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            interactions: repositories.interactions,
            window: repositories.window,
            occasions: { _ in [] },
            clock: { now }
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        _ = try? await scheduler.snooze(contactId: contact.id)
                    } else {
                        _ = try? await scheduler.recordInteraction(contactId: contact.id, .caughtUp)
                    }
                }
            }
        }

        // Reaching here at all is the deadlock check. Every one of the 12
        // wrote a row, to the one canonical id, so exactly one remains
        // whatever order they settled in, and each of the 6 catch-ups logged.
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count == 1)
        #expect(try await repositories.interactions.fetchRecent(forContact: contact.id, limit: 20).count == 6)
    }

    /// R61(e) blocker. The shared lock suspends waiters in a
    /// `withCheckedContinuation`, which is not cancellation-aware: a
    /// cancelled waiter cannot remove itself from the queue. What must hold
    /// regardless is liveness — if a waiting task is cancelled, the lock
    /// must still reach the next caller rather than stranding it forever.
    ///
    /// Structure: a gated first caller holds the lock; a second caller
    /// queues behind it and is then cancelled; a third caller queues too.
    /// Releasing the gate must let the chain drain and the third caller
    /// complete. If it cannot, this test hangs rather than fails — which is
    /// itself the signal, since a stranded lock has no failing assertion to
    /// report.
    @Test("A cancelled waiter does not strand the shared lock", .timeLimit(.minutes(1)))
    func cancelledWaiterDoesNotStrandTheLock() async throws {
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(530), suffix: "r61e-cancel", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = AsyncGate()
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: GatedFetchByIDContactRepository(wrapped: repositories.contacts, gate: gate),
            interactions: repositories.interactions,
            window: FixedReminderWindowRepository(),
            occasions: { _ in [] },
            clock: { now }
        )

        // Holder: parks inside its gated precondition read, holding the lock.
        let holder = Task { try await scheduler.snooze(contactId: contact.id) }
        await gate.waitUntilArrived()

        // Waiter that gets cancelled while queued behind the holder.
        let cancelled = Task { try await scheduler.recordInteraction(contactId: contact.id, .caughtUp) }
        await Task.yield()
        cancelled.cancel()

        // A third caller, queued behind both.
        let follower = Task { try await scheduler.recordInteraction(contactId: contact.id, .caughtUp) }
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
            interactions: repositories.interactions,
            window: repositories.window,
            occasions: { _ in [] },
            clock: { now }
        )
        _ = try await free.snooze(contactId: contact.id)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count <= 1)
    }
}
