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
    /// snooze is cleared" is provable rather than assumed — `caughtUp`
    /// against a contact with nothing pending is a silent no-op either way,
    /// which wouldn't discriminate "ran" from "was skipped."
    @Test("A caught-up write that fails only at the final contact-upsert step still clears the snooze and logs it")
    func markCaughtUpClearsSnoozeAndLogsEvenWhenContactUpsertThrows() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, clock: { Self.now })
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
        // exactly as overdue as before the action, and the snooze that
        // would otherwise have suppressed it is already gone — the row
        // belongs back in view, not left in its optimistically-removed
        // state.
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == contact.lastInteractedAt)
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
    /// either way. `GatedUpdateStateReminderRepository` closes that hole: it
    /// holds `scheduler.caughtUp`'s write open, so this test can inspect
    /// `totalCount` in the exact window *before* `markCaughtUp` reaches its
    /// own reload — the only place the bug is actually observable.
    @Test("A load() in flight when markCaughtUp fires does not overwrite the removal before its own reload lands")
    func markCaughtUpSurvivesConcurrentInFlightLoad() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let baseContacts = StubContactRepository([contact])
        let contactsGate = AsyncGate()
        let gatedContacts = GatedFetchTrackedContactRepository(wrapped: baseContacts, gate: contactsGate)
        let reminders = StubReminderRepository()
        let schedulerGate = AsyncGate()
        let gatedReminders = GatedUpdateStateReminderRepository(wrapped: reminders, gate: schedulerGate)
        let window = ReminderWindow.allDayEveryDay(timezone: UpcomingFixtures.utc, digestHorizonDays: 5)
        let viewModel = UpcomingViewModel(
            contacts: gatedContacts,
            reminders: reminders,
            scheduler: SchedulingPass(reminders: gatedReminders, clock: { Self.now }),
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
