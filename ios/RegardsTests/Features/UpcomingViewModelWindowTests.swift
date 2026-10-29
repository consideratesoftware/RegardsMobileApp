import Foundation
import Testing
@testable import Regards

/// TF-05 slice 2: Upcoming reads the live global window and each contact's own
/// override (ARCHITECTURE.md §9, R9b). The override is resolved for
/// `nextAllowedSlot` only; horizon, time zone and day headers stay global.
/// Every instant is written as an ISO-8601 UTC string so the expectations do
/// not depend on the calendar code under test.
///
/// The editor-side DST tests are elsewhere:
/// `saveAllowedForSundayWindowOnSpringForwardDay` in
/// `ReminderWindowsViewModelTests` and `timeOfDayDateRoundTripAllMinutes` in
/// `ReminderWindowPersistenceTests`.
@MainActor
struct UpcomingViewModelWindowTests {

    /// Fri 2027-01-15 08:00 UTC, the shared Upcoming fixture clock.
    private static let now = UpcomingFixtures.now

    private static func utc(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    /// Weekdays 18:00 to 22:00 in UTC, the global window of the override tests.
    private static let weekdayEvenings = ReminderWindow(
        allowedDays: .weekdays,
        allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
        timezoneIdentifier: "Etc/UTC"
    )

    private static func viewModel(
        contacts: [Contact],
        reminders: [ScheduledReminder] = [],
        window: ReminderWindow,
        now: Date = UpcomingViewModelWindowTests.now
    ) -> UpcomingViewModel {
        let contactsRepository = StubContactRepository(contacts)
        let remindersRepository = StubReminderRepository(reminders)
        return UpcomingViewModel(
            contacts: contactsRepository,
            reminders: remindersRepository,
            scheduler: SchedulingPass(
                reminders: remindersRepository,
                contacts: contactsRepository,
                window: FixedReminderWindowRepository(),
                occasions: { _ in [] },
                clock: { now }
            ),
            interactions: StubInteractionRepository(),
            window: window,
            clock: { now }
        )
    }

    private static func cadenceRow(for contact: Contact, in viewModel: UpcomingViewModel) -> UpcomingRowState? {
        viewModel.groups.flatMap(\.rows).first { $0.contactId == contact.id && $0.kind == .cadence }
    }

    @Test("A contact's own window decides its overdue row; a contact without one follows the global window")
    func overrideWindowReshapesCadenceRow() async throws {
        let saturdayMorning = ReminderWindow(
            allowedDays: .saturday,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12))],
            timezoneIdentifier: "Etc/UTC"
        )
        let overridden = UpcomingFixtures.contact(
            systemRef: "override-a", displayName: "Override", cadenceDays: 7,
            reminderWindowOverride: saturdayMorning
        )
        let plain = UpcomingFixtures.contact(systemRef: "override-b", displayName: "Default", cadenceDays: 7)
        let viewModel = Self.viewModel(contacts: [overridden, plain], window: Self.weekdayEvenings)

        await viewModel.load()

        #expect(Self.cadenceRow(for: overridden, in: viewModel)?.scheduledFor == (try Self.utc("2027-01-16T10:00:00Z")))
        #expect(Self.cadenceRow(for: plain, in: viewModel)?.scheduledFor == (try Self.utc("2027-01-15T18:00:00Z")))
    }

    @Test("Replacing the window drops rows outside the new horizon and shortens horizonDays")
    func updateWindowReshapesRowsAndHorizon() async throws {
        // Due in 10 days: inside a 14-day horizon, outside a 7-day one.
        let contact = UpcomingFixtures.contact(
            systemRef: "horizon", cadenceDays: 14,
            lastInteractedAt: Self.now.addingTimeInterval(-4 * 86_400)
        )
        let wide = ReminderWindow.allDayEveryDay(timezone: UpcomingFixtures.utc, digestHorizonDays: 14)
        let narrow = ReminderWindow.allDayEveryDay(timezone: UpcomingFixtures.utc, digestHorizonDays: 7)
        let viewModel = Self.viewModel(contacts: [contact], window: wide)
        await viewModel.load()
        #expect(viewModel.totalCount == 1)
        #expect(viewModel.horizonDays == 14)

        await viewModel.updateWindow(narrow)

        #expect(viewModel.totalCount == 0)
        #expect(viewModel.horizonDays == 7)
        #expect(viewModel.window == narrow)
    }

    @Test("A stored override with no capacity skips only that contact's cadence row")
    func storedZeroCapacityOverrideSkipsOnlyThatContact() async throws {
        // Valid structurally (so it decodes), but quiet hours 17:00 to 23:00
        // cover the whole 18:00 to 22:00 range. Legacy data can hold this.
        let noCapacity = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
            quietHours: TimeRange(start: TimeOfDay(hour: 17), end: TimeOfDay(hour: 23)),
            timezoneIdentifier: "Etc/UTC"
        )
        #expect(noCapacity.isValid)
        #expect(ReminderEngine().nextAllowedSlot(from: Self.now, in: noCapacity) == nil)
        let stuck = UpcomingFixtures.contact(
            systemRef: "zero-override", displayName: "Stuck", cadenceDays: 7,
            reminderWindowOverride: noCapacity
        )
        let others = [
            UpcomingFixtures.contact(systemRef: "zero-other-1", displayName: "Other One", cadenceDays: 7),
            UpcomingFixtures.contact(systemRef: "zero-other-2", displayName: "Other Two", cadenceDays: 7),
        ]
        let viewModel = Self.viewModel(
            contacts: [stuck] + others,
            window: ReminderWindow.allDayEveryDay(timezone: UpcomingFixtures.utc)
        )

        await viewModel.load()

        #expect(viewModel.loadState == .loaded)
        let rowContactIDs = Set(viewModel.groups.flatMap(\.rows).map(\.contactId))
        #expect(rowContactIDs == Set(others.map(\.id)))
    }

    /// The override reaches `nextAllowedSlot` only. Horizon, time zone and day
    /// headers stay global (I4). The override here sits 14 hours ahead of UTC
    /// with a 30-day horizon, so any leak into those three shows up:
    /// - A is due in 10 days. The global 7-day horizon excludes it; a leaked
    ///   30-day horizon would show it.
    /// - B's slot is 01:00 Saturday in Kiritimati, which is 11:00 Friday UTC.
    ///   The row must read "11:00 am" under "Today", not "1:00 am" under
    ///   "Tomorrow".
    @Test("An override never changes the horizon, the time zone, or the day headers")
    func overrideNeverChangesHorizonTimezoneOrHeaders() async throws {
        let global = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay.endOfDay)],
            timezoneIdentifier: "Etc/UTC",
            digestHorizonDays: 7
        )
        let allDayKiritimati = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay.endOfDay)],
            timezoneIdentifier: "Pacific/Kiritimati",
            digestHorizonDays: 30
        )
        let earlyMorningKiritimati = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 1), end: TimeOfDay(hour: 2))],
            timezoneIdentifier: "Pacific/Kiritimati",
            digestHorizonDays: 30
        )
        let tenDaysOut = UpcomingFixtures.contact(
            systemRef: "horizon-leak", cadenceDays: 14,
            reminderWindowOverride: allDayKiritimati,
            lastInteractedAt: Self.now.addingTimeInterval(-4 * 86_400)
        )
        let inside = UpcomingFixtures.contact(
            systemRef: "zone-leak", cadenceDays: 7,
            reminderWindowOverride: earlyMorningKiritimati
        )
        // Both would show under the override's own 30-day horizon.
        let tenDaysSlot = try #require(ReminderEngine().nextAllowedSlot(
            from: Self.now.addingTimeInterval(10 * 86_400), in: allDayKiritimati, includingContainingSlot: false
        ))
        #expect(tenDaysSlot > Self.now.addingTimeInterval(8 * 86_400))
        #expect(tenDaysSlot < Self.now.addingTimeInterval(30 * 86_400))
        let viewModel = Self.viewModel(contacts: [tenDaysOut, inside], window: global)

        await viewModel.load()

        #expect(Self.cadenceRow(for: tenDaysOut, in: viewModel) == nil)
        let row = try #require(Self.cadenceRow(for: inside, in: viewModel))
        #expect(row.scheduledFor == (try Self.utc("2027-01-15T11:00:00Z")))
        #expect(row.timeOfDayText == "11:00 am")
        #expect(row.dayHeader == "Today · Fri Jan 15")
        #expect(viewModel.groups.map(\.header) == ["Today · Fri Jan 15"])
    }

    /// 2026-03-08 is the US spring-forward Sunday: 02:00 EST jumps to 03:00 EDT.
    /// 07:00 on that day is 11:00 UTC. Adding 7 hours to local midnight would
    /// give 08:00 EDT (12:00 UTC), so the wrong answer is one hour off.
    @Test("An override window on the spring-forward Sunday fires at the wall-clock time")
    func overrideOnSpringForwardDayUsesWallClock() async throws {
        let newYork = "America/New_York"
        let sundayMorning = ReminderWindow(
            allowedDays: .sunday,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 8))],
            timezoneIdentifier: newYork
        )
        let global = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
            timezoneIdentifier: newYork
        )
        let now = try Self.utc("2026-03-08T05:30:00Z") // 00:30 EST
        let contact = UpcomingFixtures.contact(
            systemRef: "dst-override", cadenceDays: 7,
            reminderWindowOverride: sundayMorning,
            lastInteractedAt: now.addingTimeInterval(-30 * 86_400)
        )
        let viewModel = Self.viewModel(contacts: [contact], window: global, now: now)

        await viewModel.load()

        #expect(Self.cadenceRow(for: contact, in: viewModel)?.scheduledFor == (try Self.utc("2026-03-08T11:00:00Z")))
    }

    /// R57 interplay: a pending snooze folds into the same slot search as the
    /// cadence date, so it must use the contact's own window. This pins the
    /// override-aware resolution TF-07's fix has to keep.
    @Test("A pending snooze lands in the contact's override window, not the global one")
    func snoozeFoldUsesOverrideWindow() async throws {
        let weekendMornings = ReminderWindow(
            allowedDays: .weekends,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12))],
            timezoneIdentifier: "Etc/UTC"
        )
        let contact = UpcomingFixtures.contact(
            systemRef: "snooze-override", cadenceDays: 7,
            reminderWindowOverride: weekendMornings
        )
        let snooze = ScheduledReminder(
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: try Self.utc("2027-01-19T10:00:00Z"), // Tuesday
            osNotificationId: "snooze-override",
            snoozedUntil: try Self.utc("2027-01-19T10:00:00Z")
        )
        let viewModel = Self.viewModel(
            contacts: [contact],
            reminders: [snooze],
            window: ReminderWindow.allDayEveryDay(timezone: UpcomingFixtures.utc)
        )

        await viewModel.load()

        #expect(Self.cadenceRow(for: contact, in: viewModel)?.scheduledFor == (try Self.utc("2027-01-23T10:00:00Z")))
    }

    /// The pass-written cadence row has no floor, so it is not a snooze and
    /// must not move Upcoming's own cadence row (TF-07c). Compared with the
    /// same contact and no reminder rows at all.
    @Test("A pending cadence row without a snooze floor leaves the Upcoming cadence row where it was")
    func passRowWithoutFloorIsNotASnooze() async throws {
        let contact = UpcomingFixtures.contact(systemRef: "pass-row", cadenceDays: 7)
        let passRow = ScheduledReminder(
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: try Self.utc("2027-01-30T19:00:00Z"),
            osNotificationId: "pass-row"
        )
        let window = Self.weekdayEvenings
        let withoutRow = Self.viewModel(contacts: [contact], window: window)
        let withRow = Self.viewModel(contacts: [contact], reminders: [passRow], window: window)

        await withoutRow.load()
        await withRow.load()

        let expected = try #require(Self.cadenceRow(for: contact, in: withoutRow)?.scheduledFor)
        #expect(Self.cadenceRow(for: contact, in: withRow)?.scheduledFor == expected)
    }
}
