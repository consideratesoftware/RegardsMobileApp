import Foundation
import Testing
@testable import Regards

/// Load, failure, derived-string, and action coverage for
/// `ContactDetailViewModel` (R24 — this VM previously had only
/// `ContactDetailInteractionLabelTests`' spoken-label coverage). The action
/// tests (`markCaughtUp`, `logOther`) lock in ARCHITECTURE.md §14 PR22: both
/// persist through `ContactRepository`/`InteractionRepository` directly, and
/// both also clear any pending snooze through `SchedulingPass.caughtUp` —
/// `ScheduledReminder`'s sole writer stays `SchedulingPass` (decision #36),
/// never a direct write from this view model.
@MainActor
struct ContactDetailViewModelTests {

    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func contact(
        id: UUID = UUID(),
        priorityTier: PriorityTier = .close,
        cadenceDays: Int? = 14,
        preferredChannel: Channel = .whatsapp,
        lastInteractedAt: Date? = nil,
        createdAt: Date = now.addingTimeInterval(-100 * 86_400)
    ) -> Contact {
        Contact(
            id: id,
            systemContactRef: "sys-\(id.uuidString)",
            displayName: "Leia Organa",
            tracked: true,
            cadenceDays: cadenceDays,
            priorityTier: priorityTier,
            preferredChannel: preferredChannel,
            preferredChannelValue: "+14155550140",
            lastInteractedAt: lastInteractedAt,
            createdAt: createdAt
        )
    }

    // MARK: - Load

    @Test("A successful load exposes the contact and its recent interactions")
    func loadExposesContactAndInteractions() async throws {
        let contact = Self.contact()
        let log = InteractionLog(
            contactId: contact.id,
            occurredAt: Self.now.addingTimeInterval(-86_400),
            source: .manual,
            channel: .phoneCall
        )
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository([log]),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.contact?.id == contact.id)
        #expect(viewModel.interactions.count == 1)
        #expect(viewModel.interactions[0].id == log.id)
    }

    @Test("A failing contact fetch clears contact and interactions")
    func failedLoadClearsState() async throws {
        let viewModel = ContactDetailViewModel(
            contactId: UUID(),
            contacts: StubContactRepository.failing(),
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.contact == nil)
        #expect(viewModel.interactions.isEmpty)
    }

    @Test("A failing interaction fetch clears contact and interactions even though the contact read succeeded")
    func failedInteractionFetchClearsState() async throws {
        let contact = Self.contact()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository.failing(),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.contact == nil)
        #expect(viewModel.interactions.isEmpty)
    }

    // MARK: - Derived strings

    @Test(
        "priorityLabel maps every tier to its spoken phrase",
        arguments: [
            (PriorityTier.innerCircle, "inner circle"),
            (PriorityTier.close, "close friend"),
            (PriorityTier.regular, "regular"),
            (PriorityTier.acquaintance, "acquaintance"),
        ]
    )
    func priorityLabelMapsEveryTier(tier: PriorityTier, expected: String) async throws {
        let contact = Self.contact(priorityTier: tier)
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.priorityLabel == expected)
    }

    @Test("cadenceLabel reports 'not tracked' when the contact has no cadence")
    func cadenceLabelReportsNotTracked() async throws {
        let contact = Self.contact(cadenceDays: nil)
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.cadenceLabel == "not tracked")
    }

    @Test("lastTalkedLabel reports 'never' when the contact has no interaction")
    func lastTalkedLabelReportsNever() async throws {
        let contact = Self.contact(lastInteractedAt: nil)
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.lastTalkedLabel == "never")
    }

    @Test("overdueSummary reports overdue days once the cadence has elapsed")
    func overdueSummaryReportsOverdueDays() async throws {
        let contact = Self.contact(cadenceDays: 7, lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            clock: { Self.now },
            calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
                return calendar
            }()
        )

        await viewModel.load()

        #expect(viewModel.overdueSummary.isOverdue)
        #expect(viewModel.overdueSummary.days == 3)
    }

    // MARK: - Actions (R11 / PR22)

    @Test("Caught up logs the interaction against the preferred channel and moves lastInteractedAt")
    func markCaughtUpPersistsAndReloads() async throws {
        let contact = Self.contact(preferredChannel: .signal, lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.markCaughtUp()

        #expect(viewModel.contact?.lastInteractedAt == Self.now)
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)
        #expect(logs[0].channel == .signal)
        #expect(viewModel.interactions.count == 1)
    }

    @Test("Log other logs the interaction against the chosen channel, not the preferred one")
    func logOtherPersistsChosenChannel() async throws {
        let contact = Self.contact(preferredChannel: .whatsapp, lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.logOther(channel: .email)

        #expect(viewModel.contact?.lastInteractedAt == Self.now)
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .manual)
        #expect(logs[0].channel == .email)
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
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
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
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
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
        let scheduler = SchedulingPass(reminders: reminders, clock: { Self.now })
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
