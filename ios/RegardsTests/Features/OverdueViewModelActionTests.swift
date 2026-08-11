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
    /// nothing persists at all. Here `InteractionLogging`'s two writes both
    /// succeed and only the later `scheduler.caughtUp` call throws.
    /// `.failingUpdateState()`, not `.failing()`: `performLoad()`'s reload
    /// reads `reminders.fetchAllPending()` through this same repository
    /// reference, so a broader failure would break the reload this test
    /// means to observe, not just the write under test. This is also a real
    /// discriminator, not a trivially-true assertion: `markCaughtUp` removes
    /// the row optimistically before either write runs, so if `performLoad()`
    /// recomputed from a stale (pre-action) contacts snapshot instead of a
    /// fresh fetch, this still-overdue contact would come right back — the
    /// empty result below only holds if the reload genuinely picked up the
    /// persisted `lastInteractedAt`.
    @Test("A caught-up write that fails only at the scheduler step still reloads to the truly persisted state")
    func markCaughtUpSchedulerFailureReloadsToPersistedState() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository.failingUpdateState()
        let viewModel = Self.viewModel(contacts: contacts, interactions: interactions, reminders: reminders)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        await viewModel.markCaughtUp(contactId: contact.id)

        // The first two writes truly persisted even though the scheduler
        // call threw.
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == Self.now)

        // And the reload the catch block runs reflects that persisted
        // state, not a stale re-add of the pre-action row.
        #expect(viewModel.rows.isEmpty)
    }

    @Test("A write on the same repository through a different reference is reflected live")
    func liveUpdateReflectsWriteFromAnotherReference() async throws {
        let contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = Self.viewModel(contacts: contacts)
        await viewModel.load()
        #expect(viewModel.rows.map(\.contactId) == [contact.id])

        // Simulates Contact Detail's ContactDetailViewModel, holding its own
        // reference to the same repository, marking the contact caught up.
        var updated = contact
        updated.lastInteractedAt = Self.now
        try await contacts.upsert(updated)

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

        #expect(viewModel.rows.map(\.contactId) == [contact.id])
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
