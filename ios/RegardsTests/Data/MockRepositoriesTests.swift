import Foundation
import Testing
@testable import Regards

private actor StaticReminderRepository: ReminderRepository {
    let reminders: [ScheduledReminder]

    init(_ reminders: [ScheduledReminder]) {
        self.reminders = reminders
    }

    func fetchAllPending() async throws -> [ScheduledReminder] { reminders }

    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder] {
        reminders.filter { $0.contactId == contactId }
    }

    func upsert(_ reminder: ScheduledReminder) async throws {}

    func updateState(id: UUID, state: ReminderState) async throws {}

    func delete(id: UUID) async throws {}
}

struct MockRepositoriesTests {

    @Test("Representative ContactGroup includes an archived virtual member")
    @MainActor
    func representativeGroupState() async throws {
        let now = MockRepositories.defaultNow
        let mocks = MockRepositories(now: now)
        let groups = try await mocks.groups.fetchAll()
        let group = try #require(groups.first)
        let primary = try #require(
            try await mocks.contacts.fetch(id: group.primaryContactId)
        )
        let members = try await mocks.contacts.fetchMembers(ofGroup: group.id)
        #expect(members.count == 2)
        #expect(primary.contactGroupId == group.id)
        #expect(members.contains(where: { !$0.isActive }))

        let overdueRow = try #require(
            OverdueViewModel.makeOverdueRow(
                for: primary,
                now: now,
                calendar: Calendar(identifier: .gregorian)
            )
        )
        #expect(overdueRow.isVirtualMerged)
        #expect(overdueRow.accessibilityLabel.contains(", merged contact,"))
        #expect(overdueRow.accessibilityLabel.hasSuffix("."))
    }

    @Test("Representative InteractionLog history is newest first")
    @MainActor
    func representativeInteractionState() async throws {
        let mocks = MockRepositories(now: MockRepositories.defaultNow)
        let group = try #require(try await mocks.groups.fetchAll().first)

        let interactions = try await mocks.interactions.fetchRecent(
            forContact: group.primaryContactId,
            limit: 8
        )
        #expect(interactions.count == 2)
        #expect(interactions.map(\.source) == [.reminderCaughtUp, .manual])
    }

    @Test("Representative birthday and anniversary states are pending")
    func representativeOccasionState() async throws {
        let mocks = MockRepositories(now: MockRepositories.defaultNow)

        let reminders = try await mocks.reminders.fetchAllPending()
        #expect(Set(reminders.map(\.kind)) == [.birthday, .anniversary])
        #expect(reminders.allSatisfy { $0.state == .pending })
    }

    @Test("Upcoming identities are stable and occasion rows use reminder IDs")
    @MainActor
    func stableUpcomingIDs() async throws {
        let now = MockRepositories.defaultNow
        let mocks = MockRepositories(now: now)
        let reminders = try await mocks.reminders.fetchAllPending()

        let timezone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let viewModel = UpcomingViewModel(
            contacts: mocks.contacts,
            reminders: mocks.reminders,
            window: .defaultV1(timezone: timezone),
            clock: { now }
        )

        await viewModel.load()
        let firstRows = viewModel.groups.flatMap(\.rows)
        let firstIDs = Set(firstRows.map(\.id))
        #expect(firstRows.contains(where: { $0.kind == .birthday }))
        #expect(firstRows.contains(where: { $0.kind == .anniversary }))
        #expect(firstRows.allSatisfy {
            $0.id.contactId == $0.contactId && $0.id.kind == $0.kind
        })
        #expect(firstRows.filter { $0.kind == .cadence }.allSatisfy { $0.id.reminderId == nil })
        #expect(
            Set(firstRows.compactMap(\.id.reminderId)) == Set(reminders.map(\.id))
        )

        await viewModel.load()
        let secondIDs = Set(viewModel.groups.flatMap(\.rows).map(\.id))
        #expect(secondIDs == firstIDs)
    }

    @Test("Occasion horizon follows wall-clock days across DST transitions")
    @MainActor
    func occasionHorizonUsesCalendarDays() async throws {
        try await assertOccasion(
            timezoneID: "America/Los_Angeles",
            now: (2026, 3, 1, 12),
            probeMinutesFromCalendarHorizon: 30,
            isVisible: false
        )
        try await assertOccasion(
            timezoneID: "America/Los_Angeles",
            now: (2026, 10, 25, 12),
            probeMinutesFromCalendarHorizon: -30,
            isVisible: true
        )
        try await assertOccasion(
            timezoneID: "Australia/Lord_Howe",
            now: (2026, 9, 27, 12),
            probeMinutesFromCalendarHorizon: 15,
            isVisible: false
        )
    }

    @Test("Previous-day pending occasions stay out of Upcoming")
    @MainActor
    func previousDayOccasionsAreExcluded() async throws {
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 3,
            hour: 12
        )))
        try await assertOccasion(
            timezoneID: timezone.identifier,
            nowDate: now,
            scheduledFor: try #require(calendar.date(byAdding: .day, value: -1, to: now)),
            isVisible: false
        )
    }

    @Test("Unknown contacts and reminders beyond the horizon stay out of Upcoming")
    @MainActor
    func invalidOccasionInputsAreExcluded() async throws {
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mocks = MockRepositories(now: now)
        let contact = try #require(try await mocks.contacts.fetchTracked().first)
        let reminders = [
            ScheduledReminder(
                contactId: UUID(),
                kind: .birthday,
                scheduledFor: now.addingTimeInterval(3_600),
                osNotificationId: "unknown-contact"
            ),
            ScheduledReminder(
                contactId: contact.id,
                kind: .anniversary,
                scheduledFor: now.addingTimeInterval(15 * 86_400),
                osNotificationId: "beyond-horizon"
            ),
        ]
        let viewModel = UpcomingViewModel(
            contacts: mocks.contacts,
            reminders: StaticReminderRepository(reminders),
            window: .defaultV1(timezone: timezone),
            clock: { now }
        )

        await viewModel.load()

        #expect(viewModel.groups.flatMap(\.rows).allSatisfy { $0.id.reminderId == nil })
    }

    @Test("Equal-time occasions sort deterministically and keep unique IDs")
    @MainActor
    func equalTimeOccasionsAreStableAndUnique() async throws {
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mocks = MockRepositories(now: now)
        let contacts = try await mocks.contacts.fetchTracked()
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let first = try #require(contacts.first)
        let second = try #require(contacts.dropFirst().first)
        let scheduledFor = now.addingTimeInterval(3_600)
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000A2"))
        let duplicateKindID = try #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000A3"))
        let reminders = [
            ScheduledReminder(
                id: secondID,
                contactId: second.id,
                kind: .birthday,
                scheduledFor: scheduledFor,
                osNotificationId: "second-contact"
            ),
            ScheduledReminder(
                id: duplicateKindID,
                contactId: first.id,
                kind: .birthday,
                scheduledFor: scheduledFor,
                osNotificationId: "same-contact-second-birthday"
            ),
            ScheduledReminder(
                id: firstID,
                contactId: first.id,
                kind: .birthday,
                scheduledFor: scheduledFor,
                osNotificationId: "same-contact-first-birthday"
            ),
        ]
        let viewModel = UpcomingViewModel(
            contacts: mocks.contacts,
            reminders: StaticReminderRepository(reminders),
            window: .defaultV1(timezone: timezone),
            clock: { now }
        )

        await viewModel.load()

        let occasionRows = viewModel.groups.flatMap(\.rows).filter { $0.id.reminderId != nil }
        #expect(occasionRows.map(\.contactId) == [first.id, first.id, second.id])
        #expect(occasionRows.map(\.id.reminderId) == [firstID, duplicateKindID, secondID])
        #expect(Set(occasionRows.map(\.id)).count == 3)
    }

    @MainActor
    private func assertOccasion(
        timezoneID: String,
        now: (year: Int, month: Int, day: Int, hour: Int),
        probeMinutesFromCalendarHorizon: Int,
        isVisible: Bool
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
        let horizon = try #require(calendar.date(byAdding: .day, value: 14, to: nowDate))
        let scheduledFor = try #require(
            calendar.date(byAdding: .minute, value: probeMinutesFromCalendarHorizon, to: horizon)
        )
        try await assertOccasion(
            timezoneID: timezoneID,
            nowDate: nowDate,
            scheduledFor: scheduledFor,
            isVisible: isVisible
        )
    }

    @MainActor
    private func assertOccasion(
        timezoneID: String,
        nowDate: Date,
        scheduledFor: Date,
        isVisible: Bool
    ) async throws {
        let timezone = try #require(TimeZone(identifier: timezoneID))
        let mocks = MockRepositories(now: nowDate)
        let contact = try #require(try await mocks.contacts.fetchTracked().first)
        let reminder = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            occasionDate: "08-03",
            occasionLabel: "Birthday",
            scheduledFor: scheduledFor,
            osNotificationId: "horizon-boundary"
        )
        let viewModel = UpcomingViewModel(
            contacts: mocks.contacts,
            reminders: StaticReminderRepository([reminder]),
            window: .defaultV1(timezone: timezone),
            clock: { nowDate }
        )

        await viewModel.load()

        let hasBirthday = viewModel.groups
            .flatMap(\.rows)
            .contains { $0.kind == .birthday }
        #expect(hasBirthday == isVisible)
    }

    @Test("Occasion horizon is inclusive at now and exclusive at its end")
    @MainActor
    func occasionHorizonUsesHalfOpenBounds() async throws {
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let horizonEnd = try #require(calendar.date(byAdding: .day, value: 14, to: now))
        let mocks = MockRepositories(now: now, window: .defaultV1(timezone: timezone))
        let contact = try #require(try await mocks.contacts.fetchTracked().first)
        let visible = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            scheduledFor: now,
            osNotificationId: "exact-now"
        )
        let excluded = ScheduledReminder(
            contactId: contact.id,
            kind: .anniversary,
            scheduledFor: horizonEnd,
            osNotificationId: "exact-horizon-end"
        )
        let viewModel = UpcomingViewModel(
            contacts: mocks.contacts,
            reminders: StaticReminderRepository([visible, excluded]),
            window: .defaultV1(timezone: timezone),
            clock: { now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        #expect(rows.contains { $0.id.reminderId == visible.id })
        #expect(!rows.contains { $0.id.reminderId == excluded.id })
    }
}
