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
    /// specifically so "the snooze is cleared" is provable rather than
    /// assumed — `caughtUp` against a contact with nothing pending is a
    /// silent no-op either way, which wouldn't discriminate "ran" from "was
    /// skipped."
    @Test("A caught-up write that fails only at the final contact-upsert step still clears the snooze and logs it")
    func markCaughtUpClearsSnoozeAndLogsEvenWhenContactUpsertThrows() async throws {
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
        try await scheduler.snooze(contactId: contact.id) // a real pending cadence row to clear

        await viewModel.markCaughtUp(contactId: contact.id)

        // The first write (reminder-state) truly persisted: the pending
        // snooze this test set up above is gone, even though the write
        // after it failed.
        let pending = try await reminders.fetchPending(forContact: contact.id)
        #expect(pending.isEmpty)
        // The second write's first half (interactions.append) also truly
        // persisted — only its second half (contacts.upsert) threw.
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)

        // The one field that genuinely failed to write stays at its
        // pre-action value, and `performLoad()`'s reload reflects exactly
        // that: `lastInteractedAt` never moved, so the contact is still
        // exactly as overdue as before the action — the row belongs back on
        // screen, not left in its optimistically-removed state.
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == contact.lastInteractedAt)
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

    // MARK: - Snooze (§14 PR22 SchedulingPass stub)

    @Test("Snooze removes the row instantly and writes a pending cadence reminder 7 days out")
    func snoozeRemovesRowAndWritesReminder() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let viewModel = Self.viewModel(contacts: contacts, interactions: interactions, reminders: reminders)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.snooze(contactId: contact.id)

        #expect(viewModel.rows.isEmpty)
        #expect(await interactions.appendedLogs().isEmpty) // decision #31: no interaction logged
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == contact.lastInteractedAt) // decision #31: untouched
        let pending = try await reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].kind == .cadence)
        #expect(pending[0].scheduledFor == Self.now.addingTimeInterval(7 * 86_400))
    }

    @Test("A snoozed contact's row leaves Overdue and returns once the snooze lapses")
    func snoozedRowReturnsAfterSevenDays() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let clock = MutableClock(Self.now)
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: StubInteractionRepository(),
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: clock.now),
            clock: clock.now
        )
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.snooze(contactId: contact.id)
        #expect(viewModel.rows.isEmpty)

        // Still within the snoozed week: a fresh load keeps the row hidden.
        clock.advance(by: 6 * 86_400)
        await viewModel.load()
        #expect(viewModel.rows.isEmpty)

        // Past the snoozed week: the row returns, computed via the ordinary
        // lastInteractedAt-based path (now far more than 7 days overdue).
        clock.advance(by: 2 * 86_400)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])
    }

    @Test("A second snooze re-pushes 7 days from its own call, not stacked on the first")
    func secondSnoozeRePushesFromNow() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let clock = MutableClock(Self.now)
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: StubInteractionRepository(),
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: clock.now),
            clock: clock.now
        )
        await viewModel.load()

        await viewModel.snooze(contactId: contact.id)
        clock.advance(by: 3 * 86_400)
        await viewModel.snooze(contactId: contact.id)

        let pending = try await reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1) // idempotent write-through: still one row, not two
        #expect(pending[0].scheduledFor == clock.now().addingTimeInterval(7 * 86_400))
    }

    /// The bug this closes (PR #49 hosted review): `makeOverdueRow` guards
    /// `snoozedUntil > now`, so a stale (uncleared) snoozed-until kept
    /// suppressing this row until day 7 even once the contact was genuinely
    /// overdue again — cadence 3 days puts that moment well before the
    /// stale snooze's day-7 mark, exactly where a missing
    /// `SchedulingPass.caughtUp` call would still hide the row.
    @Test("A contact caught up after a snooze reappears at the fresh short cadence, not the stale snooze")
    func caughtUpAfterSnoozeReappearsAtFreshCadence() async throws {
        let contact = Self.overdueContact(cadenceDays: 3, lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let clock = MutableClock(Self.now)
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: StubInteractionRepository(),
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: clock.now),
            clock: clock.now
        )
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.snooze(contactId: contact.id) // pending cadence @ now + 7d
        #expect(viewModel.rows.isEmpty)

        await viewModel.markCaughtUp(contactId: contact.id)
        #expect(viewModel.rows.isEmpty) // freshly caught up, not yet overdue again

        // 4 days later: genuinely overdue again at this 3-day cadence, and
        // still short of the stale snooze's day-7 mark — the window where a
        // missing `caughtUp` clear would still hide the row.
        clock.advance(by: 4 * 86_400)
        await viewModel.load()

        // `waitUntil`, not a bare `#expect`: `markCaughtUp`'s
        // `logging.markCaughtUp` call broadcasts through `contacts.upsert`,
        // which can still have a background `observeTracked()`-driven
        // reload in flight from earlier in this test — correctness fix
        // (staged review #7) reordered `markCaughtUp` to run
        // `scheduler.caughtUp` first specifically so that broadcast always
        // fires *after* the snooze is cleared, but the broadcast's own
        // reload is still a separate, unawaited Task racing this explicit
        // `load()` above. Harmless once it resolves to the same correct
        // state — mirrors `UpcomingViewModelActionTests`'s
        // `caughtUpAfterSnoozeShowsFreshDateWithShortCadence`, which polls
        // for the identical reason.
        let sawFreshRow = await waitUntil { viewModel.rows.map(\.contactId) == [contact.id] }
        #expect(sawFreshRow)
    }

    /// `makeOverdueRow`'s guard is `snoozedUntil > now`, not `>=` — at the
    /// exact instant the snooze was pushed to, it must already read as
    /// lapsed. A boundary drawn one direction or the other is invisible
    /// unless a test lands exactly on it; `advance(by: 6 * 86_400)` +
    /// `advance(by: 2 * 86_400)` in the sibling test above never actually
    /// hits the boundary itself.
    @Test("A snoozed row has returned at exactly the 7-day mark, not just after it")
    func snoozedRowReturnsAtExactSevenDayBoundary() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let clock = MutableClock(Self.now)
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: StubInteractionRepository(),
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: clock.now),
            clock: clock.now
        )
        await viewModel.load()

        await viewModel.snooze(contactId: contact.id)
        #expect(viewModel.rows.isEmpty)

        clock.advance(by: 7 * 86_400)
        await viewModel.load()

        #expect(viewModel.rows.map(\.contactId) == [contact.id])
    }

    @Test("A failing snooze write reloads to restore the true state")
    func snoozeFailureReloadsToRestoreTrueState() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        // `.failingUpsert()`, not `.failing()`: the restore path below reads
        // through this same `reminders` reference (for the snoozed-until
        // lookup), so making every call fail would fail that read too, not
        // just the write this test is about.
        let reminders = StubReminderRepository.failingUpsert()
        let viewModel = Self.viewModel(contacts: contacts, reminders: reminders)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.snooze(contactId: contact.id)

        // The write failed, so a fresh load restores the still-overdue row
        // rather than leaving the optimistic removal standing — mirrors
        // `markCaughtUpFailureReloads`.
        #expect(viewModel.rows.map(\.contactId) == [contact.id])
    }

    /// Same blocker as `markCaughtUpSurvivesConcurrentInFlightLoad`, for
    /// `snooze` — and the more serious half of it: `snooze`'s success path
    /// never calls `performLoad()` on its own (a snoozed contact needs no
    /// fresh row data, only removal), so without the `loadGeneration` bump a
    /// stale load winning this race has nothing later to self-heal it — the
    /// contact would sit in Overdue indefinitely after a successful snooze,
    /// failing §14 PR22's "moves the contact out of Overdue instantly"
    /// contract outright, not just for one frame.
    @Test("A load() in flight when snooze fires does not overwrite the optimistic removal")
    func snoozeSurvivesConcurrentInFlightLoad() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let baseContacts = StubContactRepository([contact])
        let gate = AsyncGate()
        let gatedContacts = GatedFetchTrackedContactRepository(wrapped: baseContacts, gate: gate)
        let reminders = StubReminderRepository()
        let viewModel = OverdueViewModel(
            contacts: gatedContacts,
            interactions: StubInteractionRepository(),
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
            clock: { Self.now }
        )
        await gate.open()
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await gate.close()
        let staleLoad = Task { await viewModel.load() }
        await gate.waitUntilArrived()

        await viewModel.snooze(contactId: contact.id)
        #expect(viewModel.rows.isEmpty)

        await gate.open()
        await staleLoad.value
        // No reload of this method's own follows a successful snooze — if
        // the stale load's stale row won here, nothing else would ever
        // correct it for the rest of this screen's lifetime.
        #expect(viewModel.rows.isEmpty)
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
