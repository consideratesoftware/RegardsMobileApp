import Foundation
import Testing
@testable import Regards

/// `OverdueViewModel.snooze` coverage, split out of
/// `OverdueViewModelActionTests` when that suite crossed SwiftLint's
/// 500-line file / 300-line type body limits (staged review round 8).
/// Fixtures (`now`, `overdueContact(...)`, `viewModel(...)`) stay shared
/// from that type rather than being duplicated here.
@MainActor
struct OverdueViewModelSnoozeTests {

    nonisolated private static let now = OverdueViewModelActionTests.now

    private static func overdueContact(
        id: UUID = UUID(),
        cadenceDays: Int = 7,
        lastInteractedAt: Date
    ) -> Contact {
        OverdueViewModelActionTests.overdueContact(id: id, cadenceDays: cadenceDays, lastInteractedAt: lastInteractedAt)
    }

    private static func viewModel(
        contacts: StubContactRepository,
        interactions: any InteractionRepository = StubInteractionRepository(),
        reminders: StubReminderRepository = StubReminderRepository(),
        clock: @escaping @Sendable () -> Date = { Self.now }
    ) -> OverdueViewModel {
        OverdueViewModelActionTests.viewModel(
            contacts: contacts, interactions: interactions, reminders: reminders, clock: clock
        )
    }

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

    /// The gap this pins (staged review round 8, mirrors
    /// `ContactDetailViewModelTests.snoozeOnArchivedContactWritesNothing`,
    /// the identical fix Contact Detail's own `snooze` already got in round
    /// 7): a row on screen reflects the *last* `load()`, so a contact a
    /// concurrent `ContactsReconciler` pass archived after that load can
    /// still reach this method before its own `observeTracked()` broadcast
    /// arrives. Without the `contact.isActive` guard, `SchedulingPass.snooze`
    /// has no precondition of its own (R54) and would still write a pending
    /// cadence row no `fetchTracked()`-backed screen will ever surface.
    @Test("Snooze on an archived contact does nothing and writes no reminder")
    func snoozeOnArchivedContactWritesNothing() async throws {
        var contact = Self.overdueContact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        contact.archivedAt = Self.now.addingTimeInterval(-3_600)
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let viewModel = Self.viewModel(contacts: contacts, reminders: reminders)
        await viewModel.load()
        #expect(viewModel.rows.isEmpty) // `fetchTracked()` already excludes it

        let succeeded = await viewModel.snooze(contactId: contact.id)

        #expect(succeeded == false)
        #expect(try await reminders.fetchPending(forContact: contact.id).isEmpty)
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
}
