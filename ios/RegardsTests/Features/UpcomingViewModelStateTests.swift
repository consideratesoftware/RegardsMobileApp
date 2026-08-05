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
            window: .defaultV1(timezone: Self.utc),
            clock: { Self.now }
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
            contacts: StubContactRepository([Self.contact(systemRef: "reminder-failure")]),
            reminders: StubReminderRepository.failing(),
            window: .defaultV1(timezone: Self.utc),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.loadState == .failed)
        #expect(viewModel.groups.isEmpty)
        #expect(viewModel.totalCount == 0)
    }

    @Test("A failure after a successful load discards the stale rows")
    func failureAfterSuccessDiscardsRows() async throws {
        let contact = Self.contact(systemRef: "loaded-then-failed", cadenceDays: 1)
        let loaded = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository(),
            window: .allDayEveryDay(timezone: Self.utc),
            clock: { Self.now }
        )
        await loaded.load()
        #expect(loaded.loadState == .loaded)
        #expect(loaded.totalCount > 0)

        let failing = UpcomingViewModel(
            contacts: StubContactRepository.failing(),
            reminders: StubReminderRepository(),
            window: .allDayEveryDay(timezone: Self.utc),
            clock: { Self.now }
        )
        await failing.load()

        #expect(failing.loadState == .failed)
        #expect(failing.totalCount == 0)
    }

    // MARK: - Spoken label

    @Test("An occasion row speaks its label, never the raw enum case")
    func occasionRowSpeaksItsLabel() async throws {
        let contact = Self.contact(systemRef: "spoken-occasion", displayName: "Leia Organa")
        let reminder = ScheduledReminder(
            contactId: contact.id,
            kind: .customOccasion,
            occasionLabel: "Jedi Order anniversary",
            scheduledFor: Self.now.addingTimeInterval(3_600),
            osNotificationId: "spoken-occasion"
        )
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository([reminder]),
            window: .defaultV1(timezone: Self.utc),
            clock: { Self.now }
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
        let contact = Self.contact(
            systemRef: "spoken-cadence",
            displayName: "Han Solo",
            cadenceDays: 14
        )
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository(),
            window: .allDayEveryDay(timezone: Self.utc),
            clock: { Self.now }
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
            scheduledFor: Self.now,
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
        let contact = Self.contact(systemRef: "zero-capacity", cadenceDays: 1)
        let reminder = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            scheduledFor: Self.now.addingTimeInterval(3_600),
            osNotificationId: "zero-capacity-occasion"
        )
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository([reminder]),
            window: ReminderWindow(
                allowedDays: [],
                allowedTimeRanges: [],
                timezoneIdentifier: Self.utc.identifier
            ),
            clock: { Self.now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        #expect(viewModel.loadState == .loaded)
        #expect(rows.map(\.id.reminderId) == [reminder.id])
        #expect(!rows.contains { $0.kind == .cadence })
    }

    // MARK: - Documented §9 contract 6 deviation

    @Test("A same-day cadence and occasion pair produces two distinct rows")
    func sameDayCadenceAndOccasionBothAppear() async throws {
        // §9 contract 6 says the occasion should suppress the cadence
        // reminder. `SchedulingPass` owns that rule (PR25 / TF-07, R6) and it
        // is documented as unenforced here. This test pins the current
        // behavior so the deviation is visible rather than silent: both rows
        // appear, and — critically — their IDs do not collide, so the
        // duplicate cannot corrupt identity, diffing, or ordering while it
        // lasts. TF-07 will replace this expectation with suppression.
        let contact = Self.contact(
            systemRef: "same-day-double-up",
            displayName: "Padmé Amidala",
            cadenceDays: 1
        )
        let occasion = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            scheduledFor: Self.now.addingTimeInterval(3_600),
            osNotificationId: "same-day-double-up-occasion"
        )
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository([occasion]),
            window: .allDayEveryDay(timezone: Self.utc),
            clock: { Self.now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        let forContact = rows.filter { $0.contactId == contact.id }
        #expect(forContact.count == 2)
        #expect(Set(forContact.map(\.kind)) == [.cadence, .birthday])
        #expect(Set(forContact.map(\.id)).count == 2)

        // Both land on the same local calendar day, which is what makes this
        // the contract-6 case rather than two unrelated rows.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        let days = Set(forContact.map { calendar.startOfDay(for: $0.scheduledFor) })
        #expect(days.count == 1)

        // Exactly one of the two may declare the zoom-transition source, or
        // the duplicate contact id is registered twice in one namespace and
        // the animation resolves against an arbitrary row.
        let owners = viewModel.transitionSourceRowIDs
        #expect(forContact.filter { owners.contains($0.id) }.count == 1)
    }

    @Test("Every contact owns exactly one transition source")
    func everyContactOwnsOneTransitionSource() async throws {
        let first = Self.contact(
            systemRef: "transition-first",
            displayName: "Leia Organa",
            cadenceDays: 1
        )
        let second = Self.contact(
            systemRef: "transition-second",
            displayName: "Luke Skywalker",
            cadenceDays: 1
        )
        let occasions = [first, second].enumerated().map { index, contact in
            ScheduledReminder(
                contactId: contact.id,
                kind: .birthday,
                scheduledFor: Self.now.addingTimeInterval(TimeInterval(3_600 * (index + 1))),
                osNotificationId: "transition-occasion-\(index)"
            )
        }
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([first, second]),
            reminders: StubReminderRepository(occasions),
            window: .allDayEveryDay(timezone: Self.utc),
            clock: { Self.now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        let owners = viewModel.transitionSourceRowIDs
        #expect(rows.count > owners.count)
        #expect(owners.count == 2)
        for contactId in [first.id, second.id] {
            let owned = rows.filter { $0.contactId == contactId && owners.contains($0.id) }
            #expect(owned.count == 1)
        }
    }

    // MARK: - Archived contacts

    @Test("An archived but still tracked contact produces no rows")
    func archivedContactProducesNoRows() async throws {
        // The shared fake must match both production implementations, which
        // filter on `tracked && archivedAt == nil`. Filtering on `tracked`
        // alone would leave archived contacts visible in every fake-driven
        // test (R23 mock/production drift).
        var archived = Self.contact(
            systemRef: "archived-but-tracked",
            displayName: "Archived Contact",
            cadenceDays: 1
        )
        archived.archivedAt = Self.now.addingTimeInterval(-86_400)
        let occasion = ScheduledReminder(
            contactId: archived.id,
            kind: .birthday,
            scheduledFor: Self.now.addingTimeInterval(3_600),
            osNotificationId: "archived-occasion"
        )
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([archived]),
            reminders: StubReminderRepository([occasion]),
            window: .allDayEveryDay(timezone: Self.utc),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.groups.isEmpty)
        #expect(viewModel.totalCount == 0)
    }

    // MARK: - Untracked contacts

    @Test("A pending occasion for an untracked contact never reaches Upcoming")
    func untrackedContactOccasionsAreExcluded() async throws {
        let tracked = Self.contact(systemRef: "tracked", displayName: "Leia Organa")
        let untracked = Self.contact(
            systemRef: "untracked",
            displayName: "Archived Contact",
            tracked: false
        )
        let visible = ScheduledReminder(
            contactId: tracked.id,
            kind: .birthday,
            scheduledFor: Self.now.addingTimeInterval(3_600),
            osNotificationId: "tracked-occasion"
        )
        let orphaned = ScheduledReminder(
            contactId: untracked.id,
            kind: .birthday,
            scheduledFor: Self.now.addingTimeInterval(3_600),
            osNotificationId: "untracked-occasion"
        )
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([tracked, untracked]),
            reminders: StubReminderRepository([visible, orphaned]),
            window: .defaultV1(timezone: Self.utc),
            clock: { Self.now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        #expect(rows.compactMap(\.id.reminderId) == [visible.id])
        #expect(!rows.contains { $0.contactId == untracked.id })
    }

    // MARK: - Fixtures

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static var utc: TimeZone {
        TimeZone(secondsFromGMT: 0) ?? .gmt
    }

    private static func contact(
        systemRef: String,
        displayName: String = "State Contact",
        tracked: Bool = true,
        cadenceDays: Int? = nil
    ) -> Contact {
        Contact(
            systemContactRef: systemRef,
            displayName: displayName,
            tracked: tracked,
            cadenceDays: cadenceDays,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+14155550199",
            lastInteractedAt: now.addingTimeInterval(-30 * 86_400)
        )
    }
}

private extension ReminderWindow {
    /// A window that always has capacity, so cadence rows are never dropped
    /// for window reasons in tests that are about something else.
    static func allDayEveryDay(timezone: TimeZone) -> ReminderWindow {
        ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [
                TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 23, minute: 59)),
            ],
            timezoneIdentifier: timezone.identifier
        )
    }
}
