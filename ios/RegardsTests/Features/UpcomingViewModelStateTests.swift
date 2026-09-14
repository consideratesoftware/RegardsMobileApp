import Foundation
import Testing
@testable import Regards

/// Failure, degenerate-window, and spoken-label coverage for Upcoming.
///
/// `UpcomingViewModelBoundaryTests` owns the horizon/DST/ordering boundaries;
/// this file owns the states that leave the happy path: a repository that
/// throws, a window with no capacity, a contact that is no longer tracked, and
/// the exact string VoiceOver reads for a row.
@MainActor
struct UpcomingViewModelStateTests {

    // MARK: - Failure

    @Test("A failing contact fetch clears rows and reports failure")
    func failedContactFetchReportsFailure() async throws {
        let contacts = StubContactRepository.failing()
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: StubReminderRepository(),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository(),
                contacts: contacts,
                clock: { UpcomingFixtures.now }
            ),
            interactions: StubInteractionRepository(),
            window: .defaultV1(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        #expect(viewModel.loadState == .failed)
        #expect(viewModel.groups.isEmpty)
        #expect(viewModel.totalCount == 0)
    }

    /// Consistency fix (staged review round 6): this used to propagate a
    /// failed `reminders.fetchAllPending()` straight out of `performLoad()`'s
    /// `do` block, blanking the entire screen even though
    /// `contacts.fetchTracked()` had already succeeded — the same shape of
    /// bug `OverdueViewModel.performLoadDegradesWhenPendingRemindersReadFails`
    /// pins, and the two screens disagreeing about it (one blanked, one
    /// degraded) for the identical error was the actual defect. A cadence
    /// contact — not the default `cadenceDays: nil` fixture — so a real row
    /// surviving the failure discriminates "degraded" from "coincidentally
    /// empty either way."
    @Test("A failing pending-reminder fetch degrades to no known snoozes/occasions, not a blanked screen")
    func failedReminderFetchDegradesInsteadOfBlanking() async throws {
        let contact = UpcomingFixtures.contact(systemRef: "reminder-failure", cadenceDays: 7)
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: StubReminderRepository.failing(),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository.failing(),
                contacts: contacts,
                clock: { UpcomingFixtures.now }
            ),
            interactions: StubInteractionRepository(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        // The contact's own data loaded fine — its cadence row belongs on
        // screen, snooze/occasion state or not.
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.totalCount == 1)
        #expect(viewModel.groups.flatMap(\.rows).map(\.contactId) == [contact.id])
    }

    @Test("A failure after a successful load discards the stale rows")
    func failureAfterSuccessDiscardsRows() async throws {
        let contact = UpcomingFixtures.contact(systemRef: "loaded-then-failed", cadenceDays: 1)
        let loadedContacts = StubContactRepository([contact])
        let loaded = UpcomingViewModel(
            contacts: loadedContacts,
            reminders: StubReminderRepository(),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository(),
                contacts: loadedContacts,
                clock: { UpcomingFixtures.now }
            ),
            interactions: StubInteractionRepository(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )
        await loaded.load()
        #expect(loaded.loadState == .loaded)
        #expect(loaded.totalCount > 0)

        let failingContacts = StubContactRepository.failing()
        let failing = UpcomingViewModel(
            contacts: failingContacts,
            reminders: StubReminderRepository(),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository(),
                contacts: failingContacts,
                clock: { UpcomingFixtures.now }
            ),
            interactions: StubInteractionRepository(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )
        await failing.load()

        #expect(failing.loadState == .failed)
        #expect(failing.totalCount == 0)
    }

    // MARK: - Spoken label

    @Test("An occasion row speaks its label, never the raw enum case")
    func occasionRowSpeaksItsLabel() async throws {
        let contact = UpcomingFixtures.contact(systemRef: "spoken-occasion", displayName: "Leia Organa")
        let reminder = ScheduledReminder(
            contactId: contact.id,
            kind: .customOccasion,
            occasionLabel: "Jedi Order anniversary",
            scheduledFor: UpcomingFixtures.now.addingTimeInterval(3_600),
            osNotificationId: "spoken-occasion"
        )
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: StubReminderRepository([reminder]),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository([reminder]),
                contacts: contacts,
                clock: { UpcomingFixtures.now }
            ),
            interactions: StubInteractionRepository(),
            window: .defaultV1(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        let row = try #require(viewModel.groups.flatMap(\.rows).first)
        let label = row.accessibilityLabel
        #expect(label == "Leia Organa, Jedi Order anniversary at \(row.timeOfDayText)")
        #expect(!label.contains("customOccasion"))
        #expect(!label.contains("ReminderKind"))
    }

    @Test("A cadence row speaks name and time only, not its cadence text")
    func cadenceRowOmitsCadenceTextFromItsSpokenLabel() async throws {
        // Reversed, round 12 (Sid's call — see `UpcomingRowState
        // .accessibilityLabel`/`UpcomingRow.occasion`'s doc comments): used
        // to pin the opposite. `cadenceText` is still computed on the row
        // below (model untouched) — only the label stopped reading it.
        let contact = UpcomingFixtures.contact(
            systemRef: "spoken-cadence",
            displayName: "Han Solo",
            cadenceDays: 14
        )
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: StubReminderRepository(),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository(),
                contacts: contacts,
                clock: { UpcomingFixtures.now }
            ),
            interactions: StubInteractionRepository(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        let row = try #require(viewModel.groups.flatMap(\.rows).first)
        let cadenceText = try #require(row.cadenceText, "still computed, just unread by the label")
        #expect(row.accessibilityLabel == "Han Solo at \(row.timeOfDayText)")
        #expect(!row.accessibilityLabel.contains(cadenceText))
        #expect(!row.accessibilityLabel.contains("cadence,"))
    }

    @Test("A row with no cadence or occasion text omits the phrase entirely")
    func rowWithoutTextOmitsThePhrase() {
        let row = UpcomingRowState(
            id: .init(contactId: UUID(), kind: .cadence),
            contactId: UUID(),
            name: "Chewbacca",
            kind: .cadence,
            scheduledFor: UpcomingFixtures.now,
            channel: .phoneCall,
            cadenceText: nil,
            occasionText: nil,
            timeOfDayText: "6:00 pm",
            dayHeader: "Today"
        )

        // No double space, no dangling comma.
        #expect(row.accessibilityLabel == "Chewbacca at 6:00 pm")
    }

    // MARK: - Degenerate window

    @Test("A zero-capacity window drops cadence rows but keeps occasion rows")
    func zeroCapacityWindowKeepsOccasions() async throws {
        // R4: `nextAllowedSlot` returns nil for a window with no capacity, so
        // every cadence row is skipped. Occasions are persisted, not computed
        // from the window, so they must still populate Upcoming rather than
        // leaving the screen falsely empty.
        let contact = UpcomingFixtures.contact(systemRef: "zero-capacity", cadenceDays: 1)
        let reminder = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            scheduledFor: UpcomingFixtures.now.addingTimeInterval(3_600),
            osNotificationId: "zero-capacity-occasion"
        )
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: StubReminderRepository([reminder]),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository([reminder]),
                contacts: contacts,
                clock: { UpcomingFixtures.now }
            ),
            interactions: StubInteractionRepository(),
            window: ReminderWindow(
                allowedDays: [],
                allowedTimeRanges: [],
                timezoneIdentifier: UpcomingFixtures.utc.identifier
            ),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        #expect(viewModel.loadState == .loaded)
        #expect(rows.map(\.id.reminderId) == [reminder.id])
        #expect(!rows.contains { $0.kind == .cadence })
    }

    // MARK: - Reminder state

    @Test("Only pending reminders reach Upcoming", arguments: ReminderState.allCases)
    func onlyPendingRemindersReachUpcoming(state: ReminderState) async throws {
        let contact = UpcomingFixtures.contact(systemRef: "state-\(state.rawValue)")
        var reminder = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            scheduledFor: UpcomingFixtures.now.addingTimeInterval(3_600),
            osNotificationId: "state-\(state.rawValue)"
        )
        reminder.state = state
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: StubReminderRepository([reminder]),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository([reminder]),
                contacts: contacts,
                clock: { UpcomingFixtures.now }
            ),
            interactions: StubInteractionRepository(),
            window: .defaultV1(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        let reminderIDs = viewModel.groups.flatMap(\.rows).compactMap(\.id.reminderId)
        // Both production repositories filter on state == .pending; a fired,
        // cancelled, or caught-up reminder must not keep a row.
        #expect(reminderIDs == (state == .pending ? [reminder.id] : []))
    }

    // MARK: - Archived contacts

    @Test("An archived but still tracked contact produces no rows")
    func archivedContactProducesNoRows() async throws {
        // The shared fake must match both production implementations, which
        // filter on `tracked && archivedAt == nil`. Filtering on `tracked`
        // alone would leave archived contacts visible in every fake-driven
        // test (R23 mock/production drift).
        var archived = UpcomingFixtures.contact(
            systemRef: "archived-but-tracked",
            displayName: "Archived Contact",
            cadenceDays: 1
        )
        archived.archivedAt = UpcomingFixtures.now.addingTimeInterval(-86_400)
        let occasion = ScheduledReminder(
            contactId: archived.id,
            kind: .birthday,
            scheduledFor: UpcomingFixtures.now.addingTimeInterval(3_600),
            osNotificationId: "archived-occasion"
        )
        let contacts = StubContactRepository([archived])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: StubReminderRepository([occasion]),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository([occasion]),
                contacts: contacts,
                clock: { UpcomingFixtures.now }
            ),
            interactions: StubInteractionRepository(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        #expect(viewModel.groups.isEmpty)
        #expect(viewModel.totalCount == 0)
    }

    // MARK: - Untracked contacts

    @Test("A pending occasion for an untracked contact never reaches Upcoming")
    func untrackedContactOccasionsAreExcluded() async throws {
        let tracked = UpcomingFixtures.contact(systemRef: "tracked", displayName: "Leia Organa")
        let untracked = UpcomingFixtures.contact(
            systemRef: "untracked",
            displayName: "Archived Contact",
            tracked: false
        )
        let visible = ScheduledReminder(
            contactId: tracked.id,
            kind: .birthday,
            scheduledFor: UpcomingFixtures.now.addingTimeInterval(3_600),
            osNotificationId: "tracked-occasion"
        )
        let orphaned = ScheduledReminder(
            contactId: untracked.id,
            kind: .birthday,
            scheduledFor: UpcomingFixtures.now.addingTimeInterval(3_600),
            osNotificationId: "untracked-occasion"
        )
        let contacts = StubContactRepository([tracked, untracked])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: StubReminderRepository([visible, orphaned]),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository([visible, orphaned]),
                contacts: contacts,
                clock: { UpcomingFixtures.now }
            ),
            interactions: StubInteractionRepository(),
            window: .defaultV1(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        #expect(rows.compactMap(\.id.reminderId) == [visible.id])
        #expect(!rows.contains { $0.contactId == untracked.id })
    }
}
