import Foundation
import Testing
import UserNotifications
@testable import Regards

private let contactX = UUID(uuidString: "5C1F0E52-8A3B-4D7E-9B1A-0C2D3E4F5A6B")!

/// TF-07e (§9 platform nuance, §9 contract 5, R57). Request building and
/// decoding, restored from fec13d7. Every assertion goes through the adapter's
/// pure statics, so no test touches the real `UNUserNotificationCenter` and
/// none can raise the system permission alert.
///
/// Nothing here reads the wall clock. `makeRequest` takes its `now`, and the
/// trigger instant is checked by reading the trigger's components back through
/// a GMT calendar instead of calling `nextTriggerDate()`, which is relative to
/// the real current time.
///
/// Each DST test sets the zone under test on the calendar it passes in (the
/// adapter's device calendar) and never changes `NSTimeZone.default`, because
/// Swift Testing runs suites in parallel. A UTC host can't tell `.gmt` from
/// `.current`, so the tests assert the trigger's zone is `.gmt` and its fields
/// are the fixed UTC wall time of the instant. Deleting the adapter's GMT pin
/// fails them on every host.
struct UserNotificationsAdapterRequestTests {
    private static let now = "2026-10-01T00:00:00Z"

    // MARK: Request mapping

    @Test("A cadence request keeps its identifier, title, body, category and contact id")
    func requestCarriesIdentifierContentCategoryAndContactId() throws {
        let now = try Self.utc(Self.now)
        let request = Self.cadenceRequest(fireDate: now.addingTimeInterval(3 * 3600))

        let mapped = UserNotificationsAdapter.makeRequest(request, now: now)

        #expect(mapped.identifier == "contact-\(contactX.uuidString)-cadence")
        #expect(mapped.content.title == "Time to reach out")
        #expect(mapped.content.body == "It has been a while since you talked to Ada.")
        #expect(mapped.content.categoryIdentifier == "regards.cadence")
        #expect(mapped.content.userInfo["contactId"] as? String == contactX.uuidString)
    }

    @Test("A digest request carries the digest category and no contact id")
    func digestRequestCarriesDigestCategoryWithoutContactId() throws {
        let now = try Self.utc(Self.now)
        let request = ReminderNotificationRequest(
            identifier: "digest-1790000000",
            title: "",
            body: "3 people are overdue: Ada, Grace, and Linus.",
            fireDate: now.addingTimeInterval(3 * 3600),
            contactId: nil,
            category: .digest
        )

        let mapped = UserNotificationsAdapter.makeRequest(request, now: now)

        #expect(mapped.identifier == "digest-1790000000")
        #expect(mapped.content.categoryIdentifier == "regards.digest")
        #expect(mapped.content.userInfo["contactId"] == nil)
    }

    @Test("An occasion request carries the occasion category and its contact id")
    func occasionRequestCarriesOccasionCategoryAndContactId() throws {
        let now = try Self.utc(Self.now)
        let request = Self.request(.occasion, fireDate: now.addingTimeInterval(3 * 3600))

        let mapped = UserNotificationsAdapter.makeRequest(request, now: now)

        #expect(mapped.content.categoryIdentifier == "regards.occasion")
        #expect(mapped.content.userInfo["contactId"] as? String == contactX.uuidString)
    }

    @Test("The user info a request is built with decodes back to the same contact for both actions")
    func requestUserInfoRoundTripsThroughDecoder() throws {
        let now = try Self.utc(Self.now)
        let mapped = UserNotificationsAdapter.makeRequest(
            Self.cadenceRequest(fireDate: now.addingTimeInterval(3600)), now: now
        )
        let userInfo = mapped.content.userInfo

        #expect(UserNotificationsAdapter.action(identifier: "regards.caught-up", userInfo: userInfo)
            == .caughtUp(contactX))
        #expect(UserNotificationsAdapter.action(identifier: "regards.snooze", userInfo: userInfo)
            == .snooze(contactX))
    }

    // MARK: Decoding a pending request

    @Test(
        "A built request decodes back to an equal request",
        arguments: NotificationCategory.allCases
    )
    func pendingRequestDecodesToTheSameRequest(category: NotificationCategory) throws {
        let now = try Self.utc(Self.now)
        let original = Self.request(category, fireDate: now.addingTimeInterval(3 * 3600))

        let decoded = UserNotificationsAdapter.decode(UserNotificationsAdapter.makeRequest(original, now: now))

        #expect(decoded == original)
    }

    // MARK: Privacy

    /// Title and body are display text. An identifier or contact id in either
    /// would show on the lock screen, so the built request must carry them only
    /// in `identifier` and `userInfo`. The empty-title case covers an adapter
    /// that falls back to the identifier when a request has no title.
    @Test(
        "A built request's title and body never contain a contact id, a contact- id, or a digest- id",
        arguments: [
            (
                "contact-\(contactX.uuidString)-cadence", "", "Time to catch up with Ada.",
                contactX as UUID?, NotificationCategory.cadence
            ),
            ("contact-\(contactX.uuidString)-occasion", "Birthday", "It is Ada's birthday.", contactX, .occasion),
            ("digest-1790000000", "", "3 people are overdue: Ada, Grace, and Linus.", nil, .digest),
        ]
    )
    func requestContentNeverCarriesAnIdentifier(
        identifier: String, title: String, body: String, contactId: UUID?, category: NotificationCategory
    ) throws {
        let now = try Self.utc(Self.now)
        let request = ReminderNotificationRequest(
            identifier: identifier, title: title, body: body,
            fireDate: now.addingTimeInterval(3600), contactId: contactId, category: category
        )

        let content = UserNotificationsAdapter.makeRequest(request, now: now).content

        for text in [content.title, content.body, content.subtitle] {
            #expect(!text.localizedCaseInsensitiveContains(contactX.uuidString))
            #expect(!text.contains("contact-"))
            #expect(!text.contains("digest-"))
        }
        #expect(content.title == title)
        #expect(content.body == body)
    }

    // MARK: Trigger instant

    @Test("A future fire date maps to a non-repeating calendar trigger in GMT that names that instant")
    func futureFireDateUsesNonRepeatingGMTCalendarTrigger() throws {
        let now = try Self.utc(Self.now)
        let fireDate = now.addingTimeInterval(3 * 3600)

        let mapped = UserNotificationsAdapter.makeRequest(Self.cadenceRequest(fireDate: fireDate), now: now)

        let trigger = try #require(mapped.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats == false)
        #expect(trigger.dateComponents.timeZone == .gmt)
        #expect(Self.gmtCalendar.date(from: trigger.dateComponents) == fireDate)
    }

    @Test("A fire date at or before now maps to no trigger, which delivers immediately", arguments: [-600.0, 0.0])
    func pastOrPresentFireDateDeliversImmediately(offsetFromNow: TimeInterval) throws {
        let now = try Self.utc(Self.now)
        let fireDate = now.addingTimeInterval(offsetFromNow)

        let mapped = UserNotificationsAdapter.makeRequest(Self.cadenceRequest(fireDate: fireDate), now: now)

        #expect(mapped.trigger == nil)
    }

    /// Trigger components drop sub-second precision, so a fire date 0.4 s
    /// ahead of a whole-second `now` names the second that is already `now`.
    /// A calendar trigger for that second never fires, so it must deliver
    /// immediately instead.
    @Test("A trigger instant (fire date truncated to the second) not after now maps to no trigger")
    func triggerInstantNotAfterNowDeliversImmediately() throws {
        let now = try Self.utc(Self.now)
        let fireDate = now.addingTimeInterval(0.4)

        let mapped = UserNotificationsAdapter.makeRequest(Self.cadenceRequest(fireDate: fireDate), now: now)

        #expect(mapped.trigger == nil)
    }

    @Test("A trigger instant one second after now gets a calendar trigger")
    func triggerInstantOneSecondAfterNowGetsCalendarTrigger() throws {
        let now = try Self.utc(Self.now)
        let fireDate = now.addingTimeInterval(1.0)

        let mapped = UserNotificationsAdapter.makeRequest(Self.cadenceRequest(fireDate: fireDate), now: now)

        let trigger = try #require(mapped.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats == false)
    }

    // MARK: DST (§13)

    @Test(
        "Fall-back: both occurrences of 01:30 in Los Angeles get different GMT triggers",
        arguments: [
            ("2026-11-01T08:30:00Z", 8),  // 01:30 PDT, before the clocks go back
            ("2026-11-01T09:30:00Z", 9),  // 01:30 PST, the repeated hour
        ]
    )
    func triggerHitsEachOccurrenceOfRepeatedHour(fireDate: String, utcHour: Int) throws {
        try Self.expectGMTTrigger(
            zone: "America/Los_Angeles", transition: "2026-11-01T09:00:00Z", fireDate: fireDate,
            fields: (2026, 11, 1, utcHour, 30, 0)
        )
    }

    @Test("Spring-forward: 15 minutes after the skipped hour fires at that exact GMT time")
    func triggerAcrossSpringForward() throws {
        try Self.expectGMTTrigger(
            zone: "America/New_York", transition: "2027-03-14T07:00:00Z", fireDate: "2027-03-14T07:15:00Z",
            fields: (2027, 3, 14, 7, 15, 0)
        )
    }

    @Test(
        "A 30-minute DST shift in Lord Howe fires at the exact GMT time in both directions",
        arguments: [
            ("2026-10-03T15:30:00Z", "2026-10-03T15:45:00Z", (2026, 10, 3, 15, 45, 0)),  // spring forward
            ("2027-04-03T15:00:00Z", "2027-04-03T15:15:00Z", (2027, 4, 3, 15, 15, 0)),  // fall back
        ]
    )
    func triggerAcrossLordHoweHalfHourShift(
        transition: String, fireDate: String, fields: (Int, Int, Int, Int, Int, Int)
    ) throws {
        try Self.expectGMTTrigger(
            zone: "Australia/Lord_Howe", transition: transition, fireDate: fireDate, fields: fields
        )
    }

    // MARK: Foreground presentation

    @Test("A notification that arrives while Regards is in the foreground shows a banner, the list and sound")
    func willPresentShowsBannerListAndSound() {
        #expect(UserNotificationsAdapter.foregroundPresentationOptions == [.banner, .list, .sound])
    }

    // MARK: Helpers

    private static var gmtCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private static func utc(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso), "unparseable test date \(iso)")
    }

    private static func cadenceRequest(fireDate: Date) -> ReminderNotificationRequest {
        ReminderNotificationRequest(
            identifier: "contact-\(contactX.uuidString)-cadence",
            title: "Time to reach out",
            body: "It has been a while since you talked to Ada.",
            fireDate: fireDate,
            contactId: contactX,
            category: .cadence
        )
    }

    private static func request(_ category: NotificationCategory, fireDate: Date) -> ReminderNotificationRequest {
        switch category {
        case .cadence:
            return cadenceRequest(fireDate: fireDate)
        case .digest:
            return ReminderNotificationRequest(
                identifier: "digest-1790000000", title: "",
                body: "3 people are overdue: Ada, Grace, and Linus.",
                fireDate: fireDate, contactId: nil, category: .digest
            )
        case .occasion:
            return ReminderNotificationRequest(
                identifier: "contact-\(contactX.uuidString)-occasion", title: "Birthday",
                body: "It is Ada's birthday.", fireDate: fireDate, contactId: contactX, category: .occasion
            )
        }
    }

    /// Passes `makeRequest` a calendar set to `zone` (the device zone), then
    /// asserts the trigger names GMT, carries the fixed UTC wall-clock fields
    /// of `fireDate`, and reads back as exactly `fireDate`. It first checks
    /// that `transition` really is a DST transition of `zone`, so a tz
    /// database change fails here instead of silently testing a plain day.
    private static func expectGMTTrigger(
        zone zoneIdentifier: String,
        transition: String,
        fireDate fireDateISO: String,
        fields: (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int),
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let zone = try #require(TimeZone(identifier: zoneIdentifier), sourceLocation: sourceLocation)
        let transitionDate = try utc(transition)
        let fireDate = try utc(fireDateISO)
        let now = try utc(Self.now)
        #expect(
            zone.nextDaylightSavingTimeTransition(after: transitionDate.addingTimeInterval(-1)) == transitionDate,
            "\(transition) is not a DST transition in \(zoneIdentifier)",
            sourceLocation: sourceLocation
        )

        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = zone
        let mapped = UserNotificationsAdapter.makeRequest(
            cadenceRequest(fireDate: fireDate), now: now, calendar: deviceCalendar
        )

        let trigger = try #require(mapped.trigger as? UNCalendarNotificationTrigger, sourceLocation: sourceLocation)
        let components = trigger.dateComponents
        #expect(components.timeZone == .gmt, sourceLocation: sourceLocation)
        #expect(
            [components.year, components.month, components.day, components.hour, components.minute, components.second]
                == [fields.year, fields.month, fields.day, fields.hour, fields.minute, fields.second],
            sourceLocation: sourceLocation
        )
        #expect(gmtCalendar.date(from: components) == fireDate, sourceLocation: sourceLocation)
    }
}
