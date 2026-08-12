import Foundation
import Testing
@testable import Regards

/// `ContactDetailViewModel.snooze` coverage, split out of
/// `ContactDetailViewModelTests` when that suite crossed SwiftLint's
/// 300-line type body limit (staged review round 8). Fixtures (`now`,
/// `contact(...)`) stay shared from that type rather than being duplicated
/// here.
@MainActor
struct ContactDetailViewModelSnoozeTests {

    nonisolated private static let now = ContactDetailViewModelTests.now

    private static func contact(
        preferredChannel: Channel = .whatsapp,
        cadenceDays: Int? = 14,
        lastInteractedAt: Date? = nil
    ) -> Contact {
        ContactDetailViewModelTests.contact(
            cadenceDays: cadenceDays,
            preferredChannel: preferredChannel,
            lastInteractedAt: lastInteractedAt
        )
    }

    @Test("Snooze pushes a pending cadence reminder 7 days out and logs nothing")
    func snoozePushesCadenceReminderAndLogsNothing() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.snooze()

        let pending = try await reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].kind == .cadence)
        #expect(pending[0].scheduledFor == Self.now.addingTimeInterval(7 * 86_400))
        #expect(await interactions.appendedLogs().isEmpty)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == contact.lastInteractedAt) // untouched (decision #31)
    }

    /// The gap this used to pin as a known limitation (ARCHITECTURE.md R56,
    /// staged review round 8) is now closed: `overdueSummary` folds in
    /// `pendingSnoozeDate`, refreshed by the reload `snooze()` now performs
    /// on success. This is the inverted proof the original test's own doc
    /// comment anticipated ("a red flag the moment someone starts wiring the
    /// fix") — same setup, opposite assertion.
    @Test("overdueSummary reports not-overdue immediately after a successful Snooze (R56)")
    func overdueSummaryClearsAfterSuccessfulSnooze() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), contacts: contacts, clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()
        let before = viewModel.overdueSummary
        #expect(before.isOverdue)

        let succeeded = await viewModel.snooze()
        #expect(succeeded)

        // Suppressed outright, not merely reduced: a pending-and-future
        // snooze means "not overdue right now," matching
        // `OverdueViewModel.makeOverdueRow`'s identical guard, not a
        // smaller-but-still-positive day count.
        #expect(viewModel.overdueSummary.isOverdue == false)
        #expect(viewModel.overdueSummary.days == 0)
        #expect(viewModel.pendingSnoozeDate == Self.now.addingTimeInterval(7 * 86_400))
    }

    /// The lapse side of the same fix: once the pending snooze's date has
    /// passed, `overdueSummary` must fall back to the ordinary cadence math
    /// again — mirroring `OverdueViewModel`/`UpcomingViewModel`'s "a lapsed
    /// snooze is simply not consulted" behavior, not stay suppressed
    /// forever because a snooze once existed.
    @Test("overdueSummary resumes reporting overdue once a Snooze lapses")
    func overdueSummaryResumesAfterSnoozeLapses() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let clock = MutableClock(Self.now)
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), contacts: contacts, clock: clock.now),
            clock: clock.now
        )
        await viewModel.load()

        let succeeded = await viewModel.snooze()
        #expect(succeeded)
        #expect(viewModel.overdueSummary.isOverdue == false)

        clock.advance(by: 8 * 86_400) // past the 7-day snooze target
        await viewModel.load()

        #expect(viewModel.overdueSummary.isOverdue == true)
        #expect(viewModel.overdueSummary.days > 0)
    }

    /// `snoozePushesCadenceReminderAndLogsNothing`'s failure-path sibling —
    /// every other action on this view model (`markCaughtUp`, `logOther`)
    /// already has one, `snooze` didn't. Mirrors
    /// `OverdueViewModelActionTests.snoozeFailureReloadsToRestoreTrueState`'s
    /// `.failingUpsert()` choice: `SchedulingPass.snooze` calls
    /// `reminders.upsert`, and reads stay healthy so the assertions below
    /// aren't themselves blocked by the same failure. `snooze()`'s own doc
    /// comment says why there's no reload here to test: this screen holds no
    /// state derived from the pending reminder, so a failure has nothing of
    /// this view model's own to leave stale — the proof is simply that
    /// nothing crashed and no row was ever written.
    @Test("A failing snooze write doesn't crash and leaves no pending reminder behind")
    func snoozeFailureLeavesNoPendingReminder() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let reminders = StubReminderRepository.failingUpsert()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.snooze()

        let pending = try await reminders.fetchPending(forContact: contact.id)
        #expect(pending.isEmpty)
        #expect(await interactions.appendedLogs().isEmpty)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == contact.lastInteractedAt)
    }

    /// The gap this pins (staged review round 7): `load()` fetches through
    /// `contacts.fetch(id:)`, which — unlike `fetchTracked()` — doesn't
    /// filter `archivedAt`, so this screen can still hold an archived
    /// contact if a concurrent `ContactsReconciler` pass archived it after
    /// the push. Without `snooze()`'s `contact.isActive` guard, the write
    /// would still land: `SchedulingPass.snooze` has no precondition of its
    /// own (R54), so it would write a pending cadence row that no
    /// `fetchTracked()`-backed screen (Overdue, Upcoming) will ever surface
    /// — an orphaned row, not a merely-stale one.
    @Test("Snooze on an archived contact does nothing and writes no reminder")
    func snoozeOnArchivedContactWritesNothing() async throws {
        var contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        contact.archivedAt = Self.now.addingTimeInterval(-3_600)
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()

        let succeeded = await viewModel.snooze()

        #expect(succeeded == false)
        #expect(try await reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    /// The stale-cache bug this pins (staged review round 10, fixing what
    /// round 7 shipped): `snooze()`'s `isActive` guard used to check
    /// `self.contact` — the snapshot `load()` cached — instead of a fresh
    /// read, so a contact archived *after* this screen's `load()` still
    /// read as active from that stale snapshot and got a snooze written
    /// anyway. `snoozeOnArchivedContactWritesNothing` above doesn't
    /// discriminate a cached check from a fresh one — its contact is
    /// already archived *before* `load()` even runs, so both a stale-cache
    /// check and a fresh one see it as inactive. This test archives
    /// strictly after `load()` completes, the one case a cached check gets
    /// wrong and a fresh one gets right — mirroring
    /// `OverdueViewModelSnoozeTests`, whose `snooze()` already re-fetches.
    @Test("Snooze refuses a contact archived after load(), not just before it")
    func snoozeRefusesContactArchivedAfterLoad() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-30 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.contact?.isActive == true) // genuinely active at load time

        try await contacts.archive(id: contact.id, at: Self.now)

        let succeeded = await viewModel.snooze()

        #expect(succeeded == false)
        #expect(try await reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    /// The hosted-review blocker this pins: `logOther` originally never
    /// called `scheduler.caughtUp`, unlike `markCaughtUp` — both route
    /// through `InteractionLogging`, which moves `lastInteractedAt` and
    /// never touches `ScheduledReminder`, so without the call a contact
    /// logged through another channel after a snooze kept showing the stale
    /// snoozed date. Mirrors `UpcomingViewModelActionTests`'s
    /// `caughtUpAfterSnoozeShowsFreshDateWithShortCadence`: cadence stays at
    /// the default 7 days *reduced* to 3, deliberately short enough that the
    /// fresh `overdueAt` (now + 3d) lands *before* the stale `snoozedUntil`
    /// (now + 7d) — the same shape `caughtUpAfterSnoozeBeatsStaleSnooze`
    /// widens to 10 days specifically to avoid, since a wider cadence would
    /// make the fresh date win regardless of whether the stale snooze was
    /// ever cleared, proving nothing about this bug.
    @Test("Log other after a snooze clears the stale snoozed date, not just the interaction log")
    func logOtherAfterSnoozeClearsStaleSnoozeWithShortCadence() async throws {
        // `nextAllowedSlot`'s slot-start snapping shifts a target date by up
        // to a day if the window's allowed range doesn't start at `Self.now`'s
        // exact time-of-day (08:00 UTC, matching `UpcomingViewModelActionTests`'s
        // `eightAMWindow`) — `.allDayEveryDay`'s midnight-anchored range would
        // otherwise turn the exact-equality assertions below into a same-day
        // check instead.
        let window = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 23, minute: 59))],
            timezoneIdentifier: UpcomingFixtures.utc.identifier
        )
        let contact = Self.contact(cadenceDays: 3, lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, contacts: contacts, clock: { Self.now })
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: StubInteractionRepository(),
            scheduler: scheduler,
            clock: { Self.now }
        )
        await viewModel.load()

        try await scheduler.snooze(contactId: contact.id) // pending cadence @ now + 7d
        let beforeUpcoming = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            scheduler: scheduler,
            interactions: StubInteractionRepository(),
            window: window,
            clock: { Self.now }
        )
        await beforeUpcoming.load()
        #expect(beforeUpcoming.groups.flatMap(\.rows).first?.scheduledFor == Self.now.addingTimeInterval(7 * 86_400))

        await viewModel.logOther(channel: .email)

        // The pending cadence row is gone outright — direct proof
        // `scheduler.caughtUp` ran, independent of any Upcoming math.
        let pending = try await reminders.fetchPending(forContact: contact.id)
        #expect(pending.isEmpty)

        // And the downstream effect actually visible to a user: a fresh
        // Upcoming load computes the row from now + 3d, not the stale
        // now + 7d snooze.
        let afterUpcoming = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            scheduler: scheduler,
            interactions: StubInteractionRepository(),
            window: window,
            clock: { Self.now }
        )
        await afterUpcoming.load()
        let expected = Self.now.addingTimeInterval(3 * 86_400)
        let sawFreshDate = await waitUntil {
            afterUpcoming.groups.flatMap(\.rows).first?.scheduledFor == expected
        }
        #expect(sawFreshDate)
    }
}
