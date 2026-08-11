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
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
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
    /// "the snooze is cleared" is provable rather than assumed: `caughtUp`
    /// against a contact with nothing pending is a silent no-op either way,
    /// which wouldn't discriminate "ran" from "was skipped."
    @Test("A caught-up write that fails only at the final contact-upsert step still clears the snooze and logs it")
    func markCaughtUpClearsSnoozeAndLogsEvenWhenContactUpsertThrows() async throws {
        let contact = Self.contact(
            preferredChannel: .signal,
            lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400)
        )
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, clock: { Self.now })
        try await scheduler.snooze(contactId: contact.id) // a real pending cadence row to clear
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: scheduler,
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.markCaughtUp()

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
        // pre-action value, and the catch block's reload reflects exactly
        // this mixed, truly-persisted state — not an all-succeeded or
        // all-failed story.
        #expect(viewModel.contact?.lastInteractedAt == contact.lastInteractedAt)
        #expect(viewModel.interactions.count == 1)
    }

    /// Same shape as
    /// `markCaughtUpClearsSnoozeAndLogsEvenWhenContactUpsertThrows`, driven
    /// through `logOther` instead — the sibling should-fix #1 catch block on
    /// this method needs its own proof, not an assumption that
    /// `markCaughtUp`'s coverage carries over.
    @Test("A log-other write that fails only at the final contact-upsert step still clears the snooze and logs it")
    func logOtherClearsSnoozeAndLogsEvenWhenContactUpsertThrows() async throws {
        let contact = Self.contact(
            preferredChannel: .whatsapp,
            lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400)
        )
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, clock: { Self.now })
        try await scheduler.snooze(contactId: contact.id) // a real pending cadence row to clear
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
        #expect(pending.isEmpty)
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
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
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
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
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
