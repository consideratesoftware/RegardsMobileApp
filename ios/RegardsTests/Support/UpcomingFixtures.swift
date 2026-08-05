import Foundation
@testable import Regards

/// Shared fixtures for the Upcoming suites.
///
/// `UpcomingViewModelStateTests` and `UpcomingViewModelDuplicateRowTests` are
/// one suite split for the type-body-length limit, so their contacts, clock,
/// and windows live here rather than being duplicated across both files.
enum UpcomingFixtures {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static var utc: TimeZone {
        TimeZone(secondsFromGMT: 0) ?? .gmt
    }

    static func contact(
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

extension ReminderWindow {
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
