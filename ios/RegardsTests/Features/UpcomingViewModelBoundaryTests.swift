import Foundation
import Testing
@testable import Regards

// The repository fakes live in Support/RepositoryFakes.swift so this file and
// MockRepositoriesTests.swift share one implementation.

@MainActor
struct UpcomingViewModelBoundaryTests {

    @Test("Same-day late occasions remain visible, but previous days do not")
    func sameDayLateOccasionsRemainVisible() async throws {
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 3,
            hour: 12
        )))
        let contact = Self.contact(systemRef: "same-day-late")
        let sameDay = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            scheduledFor: try #require(calendar.date(byAdding: .hour, value: -3, to: now)),
            osNotificationId: "same-day"
        )
        let previousDay = ScheduledReminder(
            contactId: contact.id,
            kind: .anniversary,
            scheduledFor: try #require(calendar.date(byAdding: .day, value: -1, to: now)),
            osNotificationId: "previous-day"
        )
        let viewModel = Self.viewModel(
            contacts: [contact],
            reminders: [sameDay, previousDay],
            now: now,
            timezone: timezone
        )

        await viewModel.load()

        let reminderIDs = Set(viewModel.groups.flatMap(\.rows).compactMap(\.id.reminderId))
        #expect(reminderIDs == [sameDay.id])
    }

    @Test("Cadence horizon is calendar-day based and exclusive at its end")
    func cadenceHorizonUsesHalfOpenCalendarBounds() async throws {
        try await assertCadenceBoundary(
            timezoneID: "UTC",
            now: (2026, 8, 3, 12)
        )
        try await assertCadenceBoundary(
            timezoneID: "America/Los_Angeles",
            now: (2026, 3, 1, 12)
        )
    }

    @Test("Persisted cadence reminders do not duplicate computed cadence rows")
    func persistedCadenceRemindersAreIgnored() async throws {
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let contact = Self.contact(systemRef: "persisted-cadence")
        let reminder = ScheduledReminder(
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: now.addingTimeInterval(3_600),
            osNotificationId: "persisted-cadence"
        )
        let viewModel = Self.viewModel(
            contacts: [contact],
            reminders: [reminder],
            now: now,
            timezone: timezone
        )

        await viewModel.load()

        #expect(viewModel.groups.isEmpty)
    }

    @Test("Blank custom-occasion labels use the Occasion fallback")
    func blankCustomOccasionUsesFallback() async throws {
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let contact = Self.contact(systemRef: "custom-occasion")
        let reminder = ScheduledReminder(
            contactId: contact.id,
            kind: .customOccasion,
            occasionLabel: "  \n  ",
            scheduledFor: now.addingTimeInterval(3_600),
            osNotificationId: "custom-occasion"
        )
        let viewModel = Self.viewModel(
            contacts: [contact],
            reminders: [reminder],
            now: now,
            timezone: timezone
        )

        await viewModel.load()

        let row = try #require(viewModel.groups.flatMap(\.rows).first)
        #expect(row.occasionText == "Occasion")
    }

    @Test("A configured horizon remains exclusive", arguments: [7, 30])
    func configuredHorizonIsExclusive(horizonDays: Int) async throws {
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let horizonEnd = try #require(
            calendar.date(byAdding: .day, value: horizonDays, to: now)
        )
        let contact = Self.contact(systemRef: "horizon-\(horizonDays)")
        let inside = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            scheduledFor: horizonEnd.addingTimeInterval(-60),
            osNotificationId: "inside-\(horizonDays)"
        )
        let boundary = ScheduledReminder(
            contactId: contact.id,
            kind: .anniversary,
            scheduledFor: horizonEnd,
            osNotificationId: "boundary-\(horizonDays)"
        )
        let viewModel = Self.viewModel(
            contacts: [contact],
            reminders: [inside, boundary],
            now: now,
            timezone: timezone
        )
        viewModel.horizonDays = horizonDays

        await viewModel.load()

        let reminderIDs = Set(viewModel.groups.flatMap(\.rows).compactMap(\.id.reminderId))
        #expect(reminderIDs == [inside.id])
    }

    @Test("Occasion filtering accepts fall-back folds and a spring-gap-normalized now")
    func occasionFilteringHandlesDSTTransitionInstants() async throws {
        let timezone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let fallDay = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 1
        )))
        let repeatedComponents = DateComponents(hour: 1, minute: 30)
        let firstFold = try #require(calendar.nextDate(
            after: fallDay,
            matching: repeatedComponents,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ))
        let lastFold = try #require(calendar.nextDate(
            after: fallDay,
            matching: repeatedComponents,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .last,
            direction: .forward
        ))
        let contact = Self.contact(systemRef: "dst-fold")
        let foldReminders = [firstFold, lastFold].enumerated().map { index, date in
            ScheduledReminder(
                contactId: contact.id,
                kind: .customOccasion,
                occasionLabel: "Fold \(index)",
                scheduledFor: date,
                osNotificationId: "fold-\(index)"
            )
        }
        let foldViewModel = Self.viewModel(
            contacts: [contact],
            reminders: foldReminders,
            now: fallDay,
            timezone: timezone
        )

        await foldViewModel.load()
        #expect(Set(foldViewModel.groups.flatMap(\.rows).compactMap(\.id.reminderId)).count == 2)

        let normalizedGapNow = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 2,
            minute: 30
        )))
        let gapReminder = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            scheduledFor: try #require(
                calendar.date(byAdding: .day, value: 13, to: normalizedGapNow)
            ),
            osNotificationId: "spring-gap"
        )
        let gapViewModel = Self.viewModel(
            contacts: [contact],
            reminders: [gapReminder],
            now: normalizedGapNow,
            timezone: timezone
        )

        await gapViewModel.load()
        #expect(gapViewModel.groups.flatMap(\.rows).first?.id.reminderId == gapReminder.id)
    }

    private func assertCadenceBoundary(
        timezoneID: String,
        now: (year: Int, month: Int, day: Int, hour: Int)
    ) async throws {
        let timezone = try #require(TimeZone(identifier: timezoneID))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let nowDate = try #require(calendar.date(from: DateComponents(
            year: now.year,
            month: now.month,
            day: now.day,
            hour: now.hour
        )))
        let horizonEnd = try #require(calendar.date(byAdding: .day, value: 14, to: nowDate))
        let insideSlot = try #require(calendar.date(byAdding: .day, value: -1, to: horizonEnd))
        let inside = Self.cadenceContact(systemRef: "inside-\(timezoneID)", slot: insideSlot)
        let boundary = Self.cadenceContact(systemRef: "boundary-\(timezoneID)", slot: horizonEnd)
        let window = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [
                TimeRange(
                    start: TimeOfDay(hour: now.hour),
                    end: TimeOfDay(hour: now.hour + 1)
                ),
            ],
            timezoneIdentifier: timezone.identifier
        )
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([inside, boundary]),
            reminders: nil,
            window: window,
            clock: { nowDate }
        )

        await viewModel.load()

        let contactIDs = Set(viewModel.groups.flatMap(\.rows).map(\.contactId))
        #expect(contactIDs.contains(inside.id))
        #expect(!contactIDs.contains(boundary.id))
    }

    private static func contact(systemRef: String) -> Contact {
        Contact(
            systemContactRef: systemRef,
            displayName: "Boundary Contact",
            tracked: true,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+14155550199"
        )
    }

    private static func cadenceContact(systemRef: String, slot: Date) -> Contact {
        Contact(
            systemContactRef: systemRef,
            displayName: "Cadence Boundary",
            tracked: true,
            cadenceDays: 1,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+14155550199",
            lastInteractedAt: slot.addingTimeInterval(-86_400)
        )
    }

    private static func viewModel(
        contacts: [Contact],
        reminders: [ScheduledReminder],
        now: Date,
        timezone: TimeZone
    ) -> UpcomingViewModel {
        UpcomingViewModel(
            contacts: StubContactRepository(contacts),
            reminders: StubReminderRepository(reminders),
            window: .defaultV1(timezone: timezone),
            clock: { now }
        )
    }
}
