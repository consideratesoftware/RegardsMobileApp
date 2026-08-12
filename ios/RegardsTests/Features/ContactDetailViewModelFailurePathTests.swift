import Foundation
import Testing
@testable import Regards

/// `ContactDetailViewModel`'s action failure paths, split out of
/// `ContactDetailViewModelTests` when that suite crossed SwiftLint's
/// 300-line type body limit. Fixtures (`now`, `contact(...)`) stay shared
/// from that type rather than being duplicated here.
///
/// What these pin: `markCaughtUp` and `logOther` are each two writes now
/// (`SchedulingPass.caughtUp`, then `InteractionLogging`, in that order —
/// see `markCaughtUp`'s doc comment for why the reminder-state write goes
/// first), so the first can persist while the second throws or partially
/// applies. Both catch blocks reload unconditionally so the screen ends up
/// agreeing with whatever actually landed.
@MainActor
struct ContactDetailViewModelFailurePathTests {

    // `nonisolated` so the `clock: { Self.now }` closures below — which are
    // `Sendable` — can read it, matching `ContactDetailViewModelTests`.
    nonisolated private static let now = ContactDetailViewModelTests.now

    private static func contact(
        preferredChannel: Channel = .whatsapp,
        lastInteractedAt: Date? = nil
    ) -> Contact {
        ContactDetailViewModelTests.contact(
            preferredChannel: preferredChannel,
            lastInteractedAt: lastInteractedAt
        )
    }

    /// The earlier version of this test made `load()` itself fail (via a
    /// failing interaction fetch), so `viewModel.contact` was already `nil`
    /// before the action ran — the assertion after the action compared `nil`
    /// to `nil` and would pass no matter what `markCaughtUp()` did. This
    /// version makes `load()` succeed and only the action's own write fail,
    /// so there is a real prior state for the failed action to (correctly)
    /// leave alone.
    @Test("A failing action leaves the view model's previously loaded state untouched")
    func failingActionLeavesStateUntouched() async throws {
        let contact = Self.contact(lastInteractedAt: nil)
        let contacts = StubContactRepository.failingUpsert([contact])
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), contacts: contacts, clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.contact?.lastInteractedAt == nil) // a real, successfully loaded state

        await viewModel.markCaughtUp()

        // `scheduler.caughtUp` runs first now and succeeds (a no-op — this
        // contact has no pending snooze). `interactions.append` then
        // succeeds too; `upsert` throws right after (documented on
        // `InteractionLogging.record`), so the catch block's `load()` fires.
        // That reload re-reads the same contact whose `upsert` just failed,
        // so `lastInteractedAt` comes back nil — the same value already on
        // screen. The stable-looking result below is the reload agreeing
        // with what's truly persisted, not evidence `load()` was skipped:
        // the catch block calls it unconditionally now (see `markCaughtUp`'s
        // doc comment on why a bare reload belongs there).
        #expect(viewModel.contact?.lastInteractedAt == nil)
    }

    /// The three-write partial-failure shape `markCaughtUp`'s doc comment
    /// added a reload for, updated for correctness #4's write-order fix
    /// (`scheduler.caughtUp` now runs *before* `InteractionLogging`, not
    /// after — see `markCaughtUp`'s doc comment): with the reminder-state
    /// write first, "only the last write fails" now means `contacts.upsert`
    /// — `InteractionLogging`'s second internal write — not
    /// `scheduler.caughtUp` (a scheduler failure now blocks everything after
    /// it by construction, so it can't produce a partial-persistence case at
    /// all). This sets up a real pending snooze first, specifically so
    /// "the snooze is restored" is provable rather than assumed: `caughtUp`
    /// against a contact with nothing pending returns `false`, which
    /// wouldn't discriminate "ran and cleared something" from "was skipped."
    ///
    /// Superseded assertion, staged review round 7: this test used to assert
    /// the pending snooze stayed cleared through the failure — the bug the
    /// coordinator's own round-4 instruction introduced (`caughtUp` before
    /// `InteractionLogging`, uncompensated). It now asserts the corrected
    /// behavior: the catch block restores the exact row `caughtUp` cleared.
    @Test("A caught-up write that fails at the final upsert step restores the cleared snooze and still logs it")
    func markCaughtUpRestoresSnoozeAndLogsEvenWhenContactUpsertThrows() async throws {
        let contact = Self.contact(
            preferredChannel: .signal,
            lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400)
        )
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now })
        try await scheduler.snooze(contactId: contact.id) // a real pending cadence row to restore
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: scheduler,
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.markCaughtUp()

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
        // pre-action value, and the catch block's reload reflects exactly
        // this mixed, truly-persisted state — not an all-succeeded or
        // all-failed story.
        #expect(viewModel.contact?.lastInteractedAt == contact.lastInteractedAt)
        #expect(viewModel.interactions.count == 1)
    }

    /// The double-failure this pins (staged review round 8) — see
    /// `OverdueViewModelActionTests
    /// .markCaughtUpDoubleFailureOnRestoreStillReportsFailure`'s sibling
    /// doc comment for the full shape. `caughtUp` clears a real snooze,
    /// `InteractionLogging` then fails, and the compensating
    /// `restorePendingAfterFailedCaughtUp` also fails — `markCaughtUp` must
    /// still return cleanly and reload to the truthfully still-overdue
    /// state, not crash or leave the view model out of sync with what
    /// actually persisted.
    @Test("A caught-up write whose own restore also fails does not crash and still reports failure")
    func markCaughtUpDoubleFailureOnRestoreStillReportsFailure() async throws {
        let contact = Self.contact(
            preferredChannel: .signal,
            lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400)
        )
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now })
        try await scheduler.snooze(contactId: contact.id) // a real row for `caughtUp` to clear
        await reminders.armTransitionFailure(from: .userCaughtUp)
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: scheduler,
            clock: { Self.now }
        )
        await viewModel.load()

        let succeeded = await viewModel.markCaughtUp()

        #expect(succeeded == false)
        #expect(try await reminders.fetchPending(forContact: contact.id).isEmpty)
        // The reload still landed — `contact` isn't `nil` and its own true
        // state (untouched `lastInteractedAt`, the one append that
        // genuinely persisted) is what's on screen, not a crash or a stale
        // pre-action snapshot.
        #expect(viewModel.contact?.lastInteractedAt == contact.lastInteractedAt)
        #expect(viewModel.interactions.count == 1)
    }

    /// Same shape as
    /// `markCaughtUpRestoresSnoozeAndLogsEvenWhenContactUpsertThrows`, driven
    /// through `logOther` instead — the sibling should-fix #1 catch block on
    /// this method needs its own proof, not an assumption that
    /// `markCaughtUp`'s coverage carries over.
    @Test("A log-other write that fails at the final upsert step restores the cleared snooze and still logs it")
    func logOtherRestoresSnoozeAndLogsEvenWhenContactUpsertThrows() async throws {
        let contact = Self.contact(
            preferredChannel: .whatsapp,
            lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400)
        )
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now })
        try await scheduler.snooze(contactId: contact.id) // a real pending cadence row to restore
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: scheduler,
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.logOther(channel: .email)

        let pending = try await reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].kind == .cadence)
        #expect(pending[0].scheduledFor == Self.now.addingTimeInterval(7 * 86_400))
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .manual)
        #expect(logs[0].channel == .email)

        #expect(viewModel.contact?.lastInteractedAt == contact.lastInteractedAt)
        #expect(viewModel.interactions.count == 1)
    }

    /// The doc comments on `markCaughtUp`/`logOther` claim `scheduler
    /// .caughtUp` runs first and a failure there "blocks everything after
    /// it by construction" — nothing tested that claim directly. Every
    /// other failure test in this file fails a *later* write, so a
    /// scheduler failure always had something already persisted to check.
    /// This is the missing case: the reminder-state write itself throws,
    /// and `InteractionLogging` must never run at all — proved here by
    /// asserting no interaction was logged and `lastInteractedAt` never
    /// moved, not just that the final state "looks" untouched.
    /// `.failing()`, not a narrower toggle: `ContactDetailViewModel.load()`
    /// never reads `reminders`, so a blanket reminders failure can't also
    /// break the reload this test's assertions depend on.
    @Test("A caught-up write that fails at the scheduler step never reaches InteractionLogging")
    func markCaughtUpNeverLogsWhenSchedulerThrowsFirst() async throws {
        let contact = Self.contact(preferredChannel: .signal, lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository.failing()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.markCaughtUp()

        #expect(await interactions.appendedLogs().isEmpty)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == nil)
        #expect(viewModel.contact?.lastInteractedAt == nil)
    }

    /// Same shape as `markCaughtUpNeverLogsWhenSchedulerThrowsFirst`, driven
    /// through `logOther` instead — see that test's doc comment.
    @Test("A log-other write that fails at the scheduler step never reaches InteractionLogging")
    func logOtherNeverLogsWhenSchedulerThrowsFirst() async throws {
        let contact = Self.contact(preferredChannel: .whatsapp, lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository.failing()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.logOther(channel: .email)

        #expect(await interactions.appendedLogs().isEmpty)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == nil)
        #expect(viewModel.contact?.lastInteractedAt == nil)
    }
}
