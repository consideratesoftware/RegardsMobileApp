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
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository.failing(),
            reminders: StubReminderRepository(),
            window: .defaultV1(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        #expect(viewModel.loadState == .failed)
        #expect(viewModel.groups.isEmpty)
        #expect(viewModel.totalCount == 0)
    }

    @Test("A failing pending-reminder fetch clears rows and reports failure")
    func failedReminderFetchReportsFailure() async throws {
        // `fetchAllPending()` made the catch branch reachable for the first
        // time: contacts can load fine and the reminder read can still throw.
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([UpcomingFixtures.contact(systemRef: "reminder-failure")]),
            reminders: StubReminderRepository.failing(),
            window: .defaultV1(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        #expect(viewModel.loadState == .failed)
        #expect(viewModel.groups.isEmpty)
        #expect(viewModel.totalCount == 0)
    }

    @Test("A failure after a successful load discards the stale rows")
    func failureAfterSuccessDiscardsRows() async throws {
        let contact = UpcomingFixtures.contact(systemRef: "loaded-then-failed", cadenceDays: 1)
        let loaded = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )
        await loaded.load()
        #expect(loaded.loadState == .loaded)
        #expect(loaded.totalCount > 0)

        let failing = UpcomingViewModel(
            contacts: StubContactRepository.failing(),
            reminders: StubReminderRepository(),
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
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository([reminder]),
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

    @Test("A cadence row speaks its cadence text")
    func cadenceRowSpeaksItsCadenceText() async throws {
        let contact = UpcomingFixtures.contact(
            systemRef: "spoken-cadence",
            displayName: "Han Solo",
            cadenceDays: 14
        )
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        let row = try #require(viewModel.groups.flatMap(\.rows).first)
        let cadenceText = try #require(row.cadenceText)
        #expect(row.accessibilityLabel == "Han Solo, \(cadenceText) at \(row.timeOfDayText)")
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
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository([reminder]),
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
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository([reminder]),
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
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([archived]),
            reminders: StubReminderRepository([occasion]),
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
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([tracked, untracked]),
            reminders: StubReminderRepository([visible, orphaned]),
            window: .defaultV1(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        #expect(rows.compactMap(\.id.reminderId) == [visible.id])
        #expect(!rows.contains { $0.contactId == untracked.id })
    }
}
