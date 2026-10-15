import Foundation
import Testing
@testable import Regards

/// Overdue membership depends on cadence alone (ARCHITECTURE.md §9,
/// `overdueAt`), never on a reminder window. Editing a contact's window must
/// not move them in or out of the Overdue list.
@MainActor
struct OverdueMembershipWindowTests {

    @Test("A contact overdue on a Wednesday with a Saturday-only override still appears in Overdue")
    func overdueMembershipIgnoresWindows() async throws {
        let wednesday = try #require(ISO8601DateFormatter().date(from: "2027-01-13T12:00:00Z"))
        let saturdayOnly = ReminderWindow(
            allowedDays: .saturday,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12))],
            timezoneIdentifier: "Etc/UTC"
        )
        let overridden = UpcomingFixtures.contact(
            systemRef: "overdue-override", displayName: "Overridden", cadenceDays: 7,
            reminderWindowOverride: saturdayOnly,
            lastInteractedAt: wednesday.addingTimeInterval(-30 * 86_400)
        )
        let plain = UpcomingFixtures.contact(
            systemRef: "overdue-plain", displayName: "Plain", cadenceDays: 7,
            lastInteractedAt: wednesday.addingTimeInterval(-30 * 86_400)
        )
        let contacts = StubContactRepository([overridden, plain])
        let reminders = StubReminderRepository()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: StubInteractionRepository(),
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, contacts: contacts, clock: { wednesday }),
            clock: { wednesday },
            calendar: calendar
        )

        await viewModel.load()

        #expect(Set(viewModel.rows.map(\.contactId)) == [overridden.id, plain.id])
    }
}
