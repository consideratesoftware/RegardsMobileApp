import Foundation
import Testing
@testable import Regards

/// "Caught up" persistence and cross-screen live updates for
/// `OverdueViewModel` (ARCHITECTURE.md §14 PR22). `OverdueViewModelTests`
/// owns the pure `makeOverdueRow` day-math suite; this file owns the async
/// action and `observeTracked()` behavior.
@MainActor
struct OverdueViewModelActionTests {

    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func overdueContact(
        id: UUID = UUID(),
        cadenceDays: Int = 7,
        lastInteractedAt: Date
    ) -> Contact {
        Contact(
            id: id,
            systemContactRef: "sys-\(id.uuidString)",
            displayName: "Leia Organa",
            tracked: true,
            cadenceDays: cadenceDays,
            priorityTier: .close,
            preferredChannel: .whatsapp,
            preferredChannelValue: "+14155550140",
            lastInteractedAt: lastInteractedAt
        )
    }

    /// A fresh `OverdueViewModel` with independent `StubReminderRepository`/
    /// `SchedulingPass` instances (tests that need to observe a snooze's
    /// write-through construct their own `reminders` and pass it to both).
    static func viewModel(
        contacts: StubContactRepository,
        interactions: any InteractionRepository = StubInteractionRepository(),
        reminders: StubReminderRepository = StubReminderRepository(),
        clock: @escaping @Sendable () -> Date = { Self.now }
    ) -> OverdueViewModel {
        OverdueViewModel(
            contacts: contacts,
            interactions: interactions,
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: clock),
            clock: clock
        )
    }

    /// Correctness fix (staged review): `performLoad()` used to propagate a
    /// failed `reminders.fetchAllPending()` straight out of its `do` block,
    /// blanking the entire screen (`rows = []`, `loadState = .failed`) even
    /// though `contacts.fetchTracked()` had already succeeded — losing every
    /// overdue row over a problem scoped to one lookup (which contacts are
    /// snoozed). `.failing()` on `reminders` alone, `contacts` untouched, so
    /// this discriminates "degrades the snooze lookup only" from "fails the
    /// whole load": if the fix regressed, `rows` would be empty and
    /// `loadState` would be `.failed` here instead.
    @Test("A failing pending-reminders read degrades to no known snoozes, not a blanked screen")
    func performLoadDegradesWhenPendingRemindersReadFails() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository.failing()
        let viewModel = Self.viewModel(contacts: contacts, reminders: reminders)

        await viewModel.load()

        // The contact is genuinely overdue and nothing about its own data
        // failed to load — the row belongs on screen, snooze state or not.
        #expect(viewModel.rows.map(\.contactId) == [contact.id])
        #expect(viewModel.loadState == .loaded)
    }

    @Test("Caught up removes the row instantly and persists the interaction")
    func markCaughtUpRemovesRowAndPersists() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let viewModel = Self.viewModel(contacts: contacts, interactions: interactions)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.markCaughtUp(contactId: contact.id)

        #expect(viewModel.rows.isEmpty)
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == Self.now)
    }

    @Test("A failing caught-up write reloads to restore the true state")
    func markCaughtUpFailureReloads() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository.failing()
        let viewModel = Self.viewModel(contacts: contacts, interactions: interactions)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.markCaughtUp(contactId: contact.id)

        // The write failed, so a fresh load restores the still-overdue row
        // rather than leaving the optimistic removal standing.
        #expect(viewModel.rows.map(\.contactId) == [contact.id])
    }

    /// The three-write partial-failure shape `markCaughtUpFailureReloads`
    /// above doesn't reach: that test fails `interactions.append` itself, so
    /// nothing persists at all. Correctness fix (staged review #7) reordered
    /// `markCaughtUp` to run `scheduler.caughtUp` *before*
    /// `InteractionLogging` — see its doc comment — so "only the last write
    /// fails" now means `InteractionLogging`'s own second write
    /// (`contacts.upsert`), not the scheduler: a scheduler failure now blocks
    /// everything after it by construction, so it can no longer produce a
    /// partial-persistence case. This sets up a real pending snooze first,
    /// specifically so "the snooze is restored" is provable rather than
    /// assumed — `caughtUp` against a contact with nothing pending returns
    /// `false`, which wouldn't discriminate "ran and cleared something" from
    /// "was skipped."
    ///
    /// Superseded assertion, staged review round 7: this test used to assert
    /// the pending snooze stayed cleared through the failure — the bug the
    /// coordinator's own round-4 instruction introduced (`caughtUp` before
    /// `InteractionLogging`, uncompensated). It now asserts the corrected
    /// behavior: the catch block restores the exact row `caughtUp` cleared.
    @Test("A caught-up write that fails at the final upsert step restores the cleared snooze and still logs it")
    func markCaughtUpRestoresSnoozeAndLogsEvenWhenContactUpsertThrows() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, clock: { Self.now })
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: interactions,
            reminders: reminders,
            scheduler: scheduler,
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])
        try await scheduler.snooze(contactId: contact.id) // a real pending cadence row to restore

        await viewModel.markCaughtUp(contactId: contact.id)

        // The reminder-state write ran, then was reverted by the catch
        // block: the same pending cadence row is back, same id, same date —
        // not a freshly computed `now + 7d`.
        let pending = try await reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].kind == .cadence)
        #expect(pending[0].scheduledFor == Self.now.addingTimeInterval(7 * 86_400))
        // The second write's first half (interactions.append) still truly
        // persisted — only its second half (contacts.upsert) threw.
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)

        // The one field that genuinely failed to write stays at its
        // pre-action value, and the restored snooze suppresses the row from
        // Overdue exactly as it did before the action ran — a failed action
        // must not leave the contact newly exposed as overdue when it was
        // snoozed a moment ago.
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == contact.lastInteractedAt)
        #expect(viewModel.rows.isEmpty)
    }

    /// The double-failure this pins (staged review round 8, "untested in
    /// all three ViewModels' restore helpers"): `caughtUp` clears a real
    /// snooze, `InteractionLogging` then fails, and the compensating
    /// `restorePendingAfterFailedCaughtUp` *also* fails. The method must
    /// still return cleanly — not crash, not throw past its own catch
    /// block — and the reload after it must show the screen's true,
    /// currently-persisted state rather than a state this failed restore
    /// only wished were true.
    @Test("A caught-up write whose own restore also fails does not crash and still reports failure")
    func markCaughtUpDoubleFailureOnRestoreStillReportsFailure() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, clock: { Self.now })
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: interactions,
            reminders: reminders,
            scheduler: scheduler,
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])
        try await scheduler.snooze(contactId: contact.id) // a real row for `caughtUp` to clear
        // Armed after the snooze above, not at construction: `caughtUp`'s own
        // `.pending → .userCaughtUp` transition must still succeed so there
        // is something genuine for the restore to fail at reverting.
        await reminders.armTransitionFailure(from: .userCaughtUp)

        let succeeded = await viewModel.markCaughtUp(contactId: contact.id)

        #expect(succeeded == false)
        // The row is genuinely stuck at `.userCaughtUp` — the restore never
        // landed — so it correctly stays out of `fetchPending`.
        #expect(try await reminders.fetchPending(forContact: contact.id).isEmpty)
        // `lastInteractedAt` never moved (the upsert failed) and no pending
        // snooze survives to suppress the row, so the reload correctly shows
        // the contact still overdue — the screen tells the truth about what
        // actually persisted, not what the failed restore wished had.
        #expect(viewModel.rows.map(\.contactId) == [contact.id])
    }

    /// The blocker this closes (staged review, predates this round —
    /// missed by three earlier reviews): `markCaughtUp`'s optimistic
    /// `rows.removeAll` never bumped `loadGeneration`, so a `performLoad()`
    /// already in flight when the action fired would still pass its own
    /// `guard generation == loadGeneration` after finishing and overwrite
    /// the optimistic removal with its own pre-action row set — the contact
    /// reappears. `GatedFetchTrackedContactRepository` makes this
    /// deterministic instead of hoping a real race reproduces: it holds
    /// `fetchTracked()` open until the test releases it, so the stale
    /// `load()` genuinely straddles the action instead of merely racing it.
    @Test("A load() in flight when markCaughtUp fires does not overwrite the optimistic removal")
    func markCaughtUpSurvivesConcurrentInFlightLoad() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let baseContacts = StubContactRepository([contact])
        let gate = AsyncGate()
        let gatedContacts = GatedFetchTrackedContactRepository(wrapped: baseContacts, gate: gate)
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let viewModel = OverdueViewModel(
            contacts: gatedContacts,
            interactions: interactions,
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
            clock: { Self.now }
        )
        await gate.open()
        await viewModel.load() // populates the initial row; gate open, so this doesn't block
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        // A second load, held open at fetchTracked() — simulates a reload
        // (pull-to-refresh, a cross-screen observeTracked() broadcast) that
        // started just before the user tapped Caught up.
        await gate.close()
        let staleLoad = Task { await viewModel.load() }
        await gate.waitUntilArrived()

        await viewModel.markCaughtUp(contactId: contact.id)
        // The action's own work (fetch/updateLastInteractedAt/append) never
        // touches the gated fetchTracked(), so it completes immediately,
        // independent of the stale load still parked at the gate.
        #expect(viewModel.rows.isEmpty)

        // Release the stale load and let it finish. If the generation bump
        // didn't happen, this is where the contact would reappear.
        await gate.open()
        await staleLoad.value
        #expect(viewModel.rows.isEmpty)
    }

    /// Rerouted off a hand-rolled `contacts.upsert(...)` (staged review round
    /// 6): production's "Caught up"/"Log other" write goes through
    /// `InteractionLogging.record()`, which calls
    /// `contacts.updateLastInteractedAt`, not `upsert`. A test that simulated
    /// the other screen's write with `upsert` directly proved
    /// `observeTracked()` fires on *that* method, not the one the app
    /// actually calls — see `ContactObservationContractTests
    /// .observeTrackedEmitsOnUpdateLastInteractedAt` for the emission
    /// contract this test's write path now shares with.
    @Test("A write on the same repository through a different reference is reflected live")
    func liveUpdateReflectsWriteFromAnotherReference() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = Self.viewModel(contacts: contacts)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        // Simulates Contact Detail's own `ContactDetailViewModel.markCaughtUp`
        // — its `InteractionLogging` call — marking the contact caught up
        // through the same repository reference.
        let logging = InteractionLogging(contacts: contacts, interactions: StubInteractionRepository())
        try await logging.markCaughtUp(contactId: contact.id, at: Self.now)

        // The write reaches Overdue through `observeTracked()`'s subscriber
        // Task, not a call this test itself awaits — `waitUntil` yields
        // cooperatively until it drains rather than sleeping a fixed delay.
        let sawEmpty = await waitUntil { viewModel.rows.isEmpty }
        #expect(sawEmpty)
    }

    @Test("Two concurrent load() calls subscribe to observeTracked() exactly once")
    func concurrentLoadSubscribesOnce() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = Self.viewModel(contacts: contacts)

        async let firstLoad: () = viewModel.load()
        async let secondLoad: () = viewModel.load()
        _ = await (firstLoad, secondLoad)

        #expect(await contacts.subscriptionCount() == 1)
        // The subscription still works after the race: a write from another
        // reference is still picked up.
        var updated = contact
        updated.lastInteractedAt = Self.now
        try await contacts.upsert(updated)
        let sawEmpty = await waitUntil { viewModel.rows.isEmpty }
        #expect(sawEmpty)
    }
}
