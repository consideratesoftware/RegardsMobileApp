import Foundation
import Testing
@testable import Regards

/// `UpcomingViewModel.markCaughtUp`'s two-write partial-failure and
/// concurrent-in-flight-load coverage, split out of
/// `UpcomingViewModelActionTests` when that suite crossed SwiftLint's
/// 300-line type body limit. Fixtures (`now`, `contact(...)`) stay shared
/// from that type rather than being duplicated here.
@MainActor
struct UpcomingViewModelRaceTests {

    nonisolated private static let now = UpcomingViewModelActionTests.now

    private static func contact(lastInteractedAt: Date) -> Contact {
        UpcomingViewModelActionTests.contact(lastInteractedAt: lastInteractedAt)
    }

    /// The three-write partial-failure shape `markCaughtUp`'s doc comment
    /// added a reload for, updated for correctness #4's write-order fix
    /// (`scheduler.caughtUp` now runs *before* `InteractionLogging`, not
    /// after — see its doc comment) — so "only the last write fails" now
    /// means `InteractionLogging`'s own second write (`contacts.upsert`),
    /// not the scheduler: a scheduler failure now blocks everything after it
    /// by construction, so it can no longer produce a partial-persistence
    /// case. This sets up a real pending snooze first, specifically so "the
    /// snooze is restored" is provable rather than assumed — `caughtUp`
    /// against a contact with nothing pending returns `false`, which
    /// wouldn't discriminate "ran and cleared something" from "was skipped."
    ///
    /// Superseded assertion, staged review round 7: this test used to assert
    /// the pending snooze stayed cleared through the failure. It now asserts
    /// the corrected behavior — the catch block restores the exact row
    /// `caughtUp` cleared, mirroring `OverdueViewModelActionTests
    /// .markCaughtUpRestoresSnoozeAndLogsEvenWhenContactUpsertThrows`.
    @Test("A caught-up write that fails at the final upsert step restores the cleared snooze and still logs it")
    func markCaughtUpRestoresSnoozeAndLogsEvenWhenContactUpsertThrows() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now })
        let window = ReminderWindow.allDayEveryDay(timezone: UpcomingFixtures.utc, digestHorizonDays: 5)
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            scheduler: scheduler,
            interactions: interactions,
            window: window,
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.totalCount == 1)
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
        // pre-action value, and the restored snooze (now + 7d) falls outside
        // this 5-day horizon — `performLoad()`'s reload correctly shows
        // nothing for this contact, mirroring what the screen showed before
        // the action ran, not a freshly exposed overdue row.
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == contact.lastInteractedAt)
        #expect(viewModel.totalCount == 0)
        #expect(viewModel.groups.isEmpty)
    }

    /// The double-failure this pins (staged review round 8) — see
    /// `OverdueViewModelActionTests
    /// .markCaughtUpDoubleFailureOnRestoreStillReportsFailure`'s sibling
    /// doc comment for the full shape. `caughtUp` clears a real snooze,
    /// `InteractionLogging` then fails, and the compensating
    /// `restorePendingAfterFailedCaughtUp` also fails — the method must
    /// still return cleanly, and the reload must show the truthfully
    /// still-overdue contact, not a state the failed restore only wished for.
    @Test("A caught-up write whose own restore also fails does not crash and still reports failure")
    func markCaughtUpDoubleFailureOnRestoreStillReportsFailure() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now })
        let window = ReminderWindow.allDayEveryDay(timezone: UpcomingFixtures.utc, digestHorizonDays: 5)
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            scheduler: scheduler,
            interactions: interactions,
            window: window,
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.totalCount == 1)
        try await scheduler.snooze(contactId: contact.id) // a real row for `caughtUp` to clear
        await reminders.armTransitionFailure(from: .userCaughtUp)

        let succeeded = await viewModel.markCaughtUp(contactId: contact.id)

        #expect(succeeded == false)
        #expect(try await reminders.fetchPending(forContact: contact.id).isEmpty)
        // `lastInteractedAt` never moved and no pending snooze survives to
        // suppress the row, so the reload correctly shows the contact still
        // due — 3 days overdue on a 7-day cadence, well inside the horizon.
        #expect(viewModel.totalCount == 1)
    }

    /// The blocker this closes (staged review, predates this round —
    /// missed by three earlier reviews): `markCaughtUp`'s optimistic
    /// mutation never bumped `loadGeneration`, so a `performLoad()` already
    /// in flight when the action fired could still resolve afterward, pass
    /// its own (unbumped) generation guard, and overwrite the optimistic
    /// removal with pre-action rows — visible as a flash of the just-caught
    /// -up contact reappearing. Unlike `OverdueViewModel`, this method's
    /// success path calls `performLoad()` itself, which *also* bumps
    /// `loadGeneration` — meaning a naive test that lets everything resolve
    /// and only checks the final state would pass whether or not the fix
    /// is present, since that trailing reload eventually self-corrects
    /// either way. `GatedTransitionStateReminderRepository` closes that
    /// hole: it holds `scheduler.caughtUp`'s write open, so this test can
    /// inspect `totalCount` in the exact window *before* `markCaughtUp`
    /// reaches its own reload — the only place the bug is actually
    /// observable.
    @Test("A load() in flight when markCaughtUp fires does not overwrite the removal before its own reload lands")
    func markCaughtUpSurvivesConcurrentInFlightLoad() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let baseContacts = StubContactRepository([contact])
        let contactsGate = AsyncGate()
        let gatedContacts = GatedFetchTrackedContactRepository(wrapped: baseContacts, gate: contactsGate)
        let reminders = StubReminderRepository()
        let schedulerGate = AsyncGate()
        let gatedReminders = GatedTransitionStateReminderRepository(wrapped: reminders, gate: schedulerGate)
        let window = ReminderWindow.allDayEveryDay(timezone: UpcomingFixtures.utc, digestHorizonDays: 5)
        let viewModel = UpcomingViewModel(
            contacts: gatedContacts,
            reminders: reminders,
            scheduler: SchedulingPass(reminders: gatedReminders, contacts: gatedContacts, clock: { Self.now }),
            interactions: StubInteractionRepository(),
            window: window,
            clock: { Self.now }
        )
        await contactsGate.open()
        await viewModel.load() // populates the initial row; gate open, so this doesn't block
        #expect(viewModel.totalCount == 1)

        // A second load, held open at fetchTracked() — simulates a reload
        // that started just before the user tapped Caught up.
        await contactsGate.close()
        let staleLoad = Task { await viewModel.load() }
        await contactsGate.waitUntilArrived()

        // markCaughtUp: its optimistic mutation runs immediately, then it
        // blocks inside `scheduler.caughtUp` before it can reach its own
        // trailing `performLoad()`.
        let action = Task { await viewModel.markCaughtUp(contactId: contact.id) }
        await schedulerGate.waitUntilArrived()
        #expect(viewModel.totalCount == 0)

        // Release the stale load now, while markCaughtUp's own reload is
        // still blocked, and wait for it to fully finish — `Task.value`
        // guarantees its write (if any) has already landed by the time this
        // returns, so the check below needs no sleep or yield-count guess.
        // If the generation bump didn't happen, this is where the contact
        // flashes back into view.
        await contactsGate.open()
        await staleLoad.value
        #expect(viewModel.totalCount == 0, "the stale load must not resurrect the row before markCaughtUp's own reload")

        // Let markCaughtUp finish: its scheduler write, then its own
        // trailing reload, both now unblocked.
        await schedulerGate.open()
        _ = await action.value
        #expect(viewModel.totalCount == 0)
    }
}
