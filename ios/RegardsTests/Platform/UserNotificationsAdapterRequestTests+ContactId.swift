import Foundation
import Testing
import UserNotifications
@testable import Regards

private let contactX = UUID(uuidString: "5C1F0E52-8A3B-4D7E-9B1A-0C2D3E4F5A6B")!

/// A cadence or occasion request always carries a contact id, and decode drops
/// one that has none. The type enforces the pairing. The file also holds the
/// decode-nil tests for a trigger this build never makes, because they share
/// the hand-built request. Shares the helpers in
/// `UserNotificationsAdapterRequestTests.swift`; like that file, nothing here
/// touches the real notification center or the wall clock.
extension UserNotificationsAdapterRequestTests {
    // MARK: Contact id pairing

    /// Caught up and Snooze read the contact id back from `userInfo`, so a cadence
    /// request without one would leave them inert. The expectation comes from
    /// the category, not from the request.
    @Test(
        "A cadence or occasion request carries its contact id in the user info and decodes with it; a digest has none",
        arguments: NotificationCategory.allCases
    )
    func cadenceAndOccasionRequestsAlwaysCarryAContactId(category: NotificationCategory) throws {
        let now = try Self.utc(Self.now)
        let expected: UUID? = category == .digest ? nil : contactX

        let mapped = UserNotificationsAdapter.makeRequest(
            Self.request(category, fireDate: now.addingTimeInterval(3600)), now: now
        )
        let decoded = try #require(UserNotificationsAdapter.decode(mapped))

        #expect(mapped.content.userInfo["contactId"] as? String == expected?.uuidString)
        #expect(decoded.contactId == expected)
    }

    // MARK: Decoding a request with no usable contact id

    /// The type can't build a cadence or occasion request without a contact id,
    /// so one on the system's list was not made by `makeRequest`. Decode drops
    /// it. A cadence request kept without one would have Caught up and Snooze
    /// that do nothing.
    @Test("A cadence request with no contact id in its user info decodes to nothing")
    func cadenceRequestWithoutContactIdDecodesToNil() {
        let request = Self.handBuilt(category: "regards.cadence", contactId: nil)

        #expect(UserNotificationsAdapter.decode(request) == nil)
    }

    @Test("An occasion request with no contact id in its user info decodes to nothing")
    func occasionRequestWithoutContactIdDecodesToNil() {
        let request = Self.handBuilt(category: "regards.occasion", contactId: nil)

        #expect(UserNotificationsAdapter.decode(request) == nil)
    }

    @Test(
        "A cadence or occasion request whose contact id is not a UUID decodes to nothing",
        arguments: ["regards.cadence", "regards.occasion"]
    )
    func requestWithMalformedContactIdDecodesToNil(category: String) {
        let request = Self.handBuilt(category: category, contactId: "not-a-uuid")

        #expect(UserNotificationsAdapter.decode(request) == nil)
    }

    /// Control for the 3 tests above: the same hand-built shape decodes when
    /// the contact id is there (and a digest needs none), so those tests get
    /// their nil from the missing id and not from the trigger or the category.
    @Test(
        "A hand-built request decodes to the kind its category names when it has the contact id it needs",
        arguments: [
            (
                "regards.cadence", contactX.uuidString as String?,
                ReminderNotificationRequest.Kind.cadence(contactId: contactX)
            ),
            ("regards.occasion", contactX.uuidString, .occasion(contactId: contactX)),
            ("regards.digest", nil, .digest),
        ]
    )
    func handBuiltRequestWithItsContactIdDecodesToItsKind(
        category: String, contactId: String?, kind: ReminderNotificationRequest.Kind
    ) throws {
        let request = Self.handBuilt(category: category, contactId: contactId)

        let decoded = try #require(UserNotificationsAdapter.decode(request))

        #expect(decoded.kind == kind)
        #expect(decoded.fireDate == (try Self.utc("2026-10-01T03:00:00Z")))
    }

    // MARK: Decoding a request with a trigger this build never makes

    /// This build makes only non-repeating calendar triggers, and a repeating
    /// request never leaves the pending list. The control above is the same
    /// request with `repeats: false`, which decodes.
    @Test("A repeating calendar trigger decodes to nothing")
    func repeatingCalendarTriggerDecodesToNil() {
        let request = Self.handBuilt(category: "regards.cadence", contactId: contactX.uuidString, repeats: true)

        #expect(UserNotificationsAdapter.decode(request) == nil)
    }

    @Test("A time-interval trigger decodes to nothing")
    func timeIntervalTriggerDecodesToNil() {
        let calendarRequest = Self.handBuilt(category: "regards.cadence", contactId: contactX.uuidString)
        let request = UNNotificationRequest(
            identifier: calendarRequest.identifier,
            content: calendarRequest.content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
        )

        #expect(UserNotificationsAdapter.decode(request) == nil)
    }

    /// `Calendar.date(from:)` fills in a field the components lack, so a trigger
    /// missing any one of the 6 would decode to a made-up date unless `decode`
    /// requires all 6. The control is `handBuiltRequestWithItsContactIdDecodesToItsKind`,
    /// which has all 6.
    @Test(
        "A calendar trigger missing one date or time field decodes to nothing",
        arguments: [Calendar.Component.year, .month, .day, .hour, .minute, .second]
    )
    func triggerMissingAnyDateOrTimeFieldDecodesToNil(missing: Calendar.Component) {
        var components = DateComponents(
            calendar: Self.gmtCalendar, timeZone: .gmt, year: 2026, month: 10, day: 1, hour: 3, minute: 0, second: 0
        )
        components.setValue(nil, for: missing)
        let calendarRequest = Self.handBuilt(category: "regards.cadence", contactId: contactX.uuidString)
        let request = UNNotificationRequest(
            identifier: calendarRequest.identifier,
            content: calendarRequest.content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )

        #expect(UserNotificationsAdapter.decode(request) == nil)
    }

    /// A pending request as the system could hold one that `makeRequest` did not
    /// build: the given category and contact id (none when nil), and a calendar
    /// trigger at 2026-10-01 03:00:00 GMT, non-repeating unless `repeats` is true.
    private static func handBuilt(
        category: String,
        contactId: String?,
        repeats: Bool = false
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Time to reach out"
        content.body = "It has been a while since you talked to Ada."
        content.categoryIdentifier = category
        if let contactId {
            content.userInfo = ["contactId": contactId]
        }
        let components = DateComponents(
            calendar: gmtCalendar, timeZone: .gmt, year: 2026, month: 10, day: 1, hour: 3, minute: 0, second: 0
        )
        return UNNotificationRequest(
            identifier: "hand-built",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        )
    }
}
