import Foundation
import Testing
@testable import Regards

/// `ContactDetailViewModel`'s action failure paths, split out of
/// `ContactDetailViewModelTests` when that suite crossed SwiftLint's
/// 300-line type body limit. Fixtures (`now`, `contact(...)`) stay shared
/// from that type rather than being duplicated here.
///
/// What these pin: `markCaughtUp` and `logOther` are each two writes now
/// (`InteractionLogging`, then `SchedulingPass.caughtUp`), so the first can
/// persist while the second throws. Both catch blocks reload
/// unconditionally so the screen ends up agreeing with whatever actually
/// landed.
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

        // `upsert` throws right after `interactions.append` already
        // succeeded (documented on `InteractionLogging.record`), so
        // `scheduler.caughtUp` never runs and the catch block's `load()`
        // fires. That reload re-reads the same contact whose `upsert` just
        // failed, so `lastInteractedAt` comes back nil — the same value
        // already on screen. The stable-looking result below is the reload
        // agreeing with what's truly persisted, not evidence `load()` was
        // skipped: the catch block calls it unconditionally now (see
        // `markCaughtUp`'s doc comment on why a bare reload belongs there).
        #expect(viewModel.contact?.lastInteractedAt == nil)
    }

    /// The three-write partial-failure shape `markCaughtUp`'s doc comment
    /// added a reload for: `InteractionLogging`'s two writes
    /// (`interactions.append`, `contacts.upsert`) both succeed, and only the
    /// later `scheduler.caughtUp` call throws. Before that fix the catch
    /// block only logged the error — the interaction row and the moved
    /// `lastInteractedAt` were genuinely persisted, but `viewModel.contact`/
    /// `viewModel.interactions` kept showing the pre-action state until the
    /// screen was left and re-entered. `.failingUpdateState()`, not
    /// `.failing()`: only `SchedulingPass.caughtUp`'s `updateState` call
    /// needs to fail here — `ContactDetailViewModel.load()` never reads
    /// `reminders` at all, so a broader failure would prove nothing extra.
    @Test("A caught-up write that fails only at the scheduler step still reloads to the truly persisted state")
    func markCaughtUpReloadsPersistedStateWhenSchedulerThrows() async throws {
        let contact = Self.contact(preferredChannel: .signal, lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository.failingUpdateState()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.markCaughtUp()

        // The first two writes truly persisted even though the third threw.
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == Self.now)

        // And the reload the catch block now runs makes the view model agree
        // with that persisted state, not the pre-action snapshot.
        #expect(viewModel.contact?.lastInteractedAt == Self.now)
        #expect(viewModel.interactions.count == 1)
    }

    /// Same shape as `markCaughtUpReloadsPersistedStateWhenSchedulerThrows`,
    /// driven through `logOther` instead — the sibling should-fix #1 catch
    /// block on this method needs its own proof, not an assumption that
    /// `markCaughtUp`'s coverage carries over.
    @Test("A log-other write that fails only at the scheduler step still reloads to the truly persisted state")
    func logOtherReloadsPersistedStateWhenSchedulerThrows() async throws {
        let contact = Self.contact(preferredChannel: .whatsapp, lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository.failingUpdateState()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.logOther(channel: .email)

        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .manual)
        #expect(logs[0].channel == .email)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == Self.now)

        #expect(viewModel.contact?.lastInteractedAt == Self.now)
        #expect(viewModel.interactions.count == 1)
    }}
