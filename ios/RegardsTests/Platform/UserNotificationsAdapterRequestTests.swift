import Foundation
import Testing
import UserNotifications
@testable import Regards

private let contactX = UUID(uuidString: "5C1F0E52-8A3B-4D7E-9B1A-0C2D3E4F5A6B")!

/// TF-07e (§9 platform nuance, §9 contract 5, R57). Request building and
/// decoding, restored from fec13d7, with a `kind` payload in place of
/// `contactId` and `category`. Every assertion goes through the adapter's
/// pure statics (except the two willPresent tests), so no test touches the real
/// `UNUserNotificationCenter` and none can raise the system permission alert.
///
/// Nothing here reads the wall clock. `makeRequest` takes its `now`, and the
/// trigger instant is checked by reading the trigger's components back through
/// a GMT calendar instead of calling `nextTriggerDate()`, which is relative to
/// the real current time.
///
/// Each DST test passes the zone under test to `makeRequest` as the device zone
/// and never changes `NSTimeZone.default`, because Swift Testing runs suites in
/// parallel. A UTC host can't tell `.gmt` from `.current`, so the tests assert
/// the trigger's zone is `.gmt` and its fields are the fixed UTC wall time of
/// the instant. Deleting the adapter's GMT pin fails them on every host.
struct UserNotificationsAdapterRequestTests {
    static let now = "2026-10-01T00:00:00Z"

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
            kind: .digest
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

    /// Pending requests this app didn't build are left out of `pendingRequests()`,
    /// so `decode` must return nil for them instead of guessing a category.
    @Test("A pending request with a category this app doesn't define decodes to nothing")
    func pendingRequestWithUnknownCategoryDecodesToNil() throws {
        let now = try Self.utc(Self.now)
        let built = UserNotificationsAdapter.makeRequest(
            Self.cadenceRequest(fireDate: now.addingTimeInterval(3600)), now: now
        )
        let content = try #require(built.content.mutableCopy() as? UNMutableNotificationContent)
        content.categoryIdentifier = "other"
        let foreign = UNNotificationRequest(identifier: built.identifier, content: content, trigger: built.trigger)

        #expect(UserNotificationsAdapter.decode(foreign) == nil)
    }

    // Renaming or removing a category leaves old requests that decode can't read,
    // so a change that does it must cancel them first (§9a).
    @Test("The category raw values are pinned")
    func categoryRawValuesArePinned() {
        #expect(
            NotificationCategory.allCases.map(\.rawValue) == ["regards.cadence", "regards.digest", "regards.occasion"]
        )
    }

    /// Contract pin for the slice 4 diff: the trigger carries whole seconds, so a
    /// pending request's fire date comes back truncated, and the diff must
    /// compare against the truncated value.
    @Test("A pending request's fire date decodes truncated to whole seconds")
    func pendingRequestFireDateDecodesTruncatedToWholeSeconds() throws {
        let now = try Self.utc(Self.now)
        let original = Self.cadenceRequest(fireDate: now.addingTimeInterval(3 * 3600 + 0.7))

        let decoded = try #require(
            UserNotificationsAdapter.decode(UserNotificationsAdapter.makeRequest(original, now: now))
        )

        #expect(decoded.fireDate == now.addingTimeInterval(3 * 3600))
        #expect(decoded.contactId == original.contactId)
        #expect(decoded.identifier == original.identifier)
    }

    @Test("A request with no trigger (it delivers at once and is never pending) decodes to nothing")
    func requestWithNoTriggerDecodesToNil() throws {
        let now = try Self.utc(Self.now)
        let immediate = UserNotificationsAdapter.makeRequest(
            Self.cadenceRequest(fireDate: now.addingTimeInterval(-600)), now: now
        )
        try #require(immediate.trigger == nil)

        #expect(UserNotificationsAdapter.decode(immediate) == nil)
    }

    // MARK: Privacy

    /// Title and body are display text. An identifier or contact id in either
    /// would show on the lock screen, so the built request must carry them only
    /// in `identifier` and `userInfo`. Title and body must also come out as
    /// given. `makeRequest` doesn't fill an empty title from anything today;
    /// the empty-title cases would fail if it started to use the identifier.
    @Test(
        "A built request's title and body never contain a contact id, a contact- id, or a digest- id",
        arguments: [
            (
                "contact-\(contactX.uuidString)-cadence", "", "Time to catch up with Ada.",
                ReminderNotificationRequest.Kind.cadence(contactId: contactX)
            ),
            (
                "contact-\(contactX.uuidString)-occasion", "Birthday", "It is Ada's birthday.",
                .occasion(contactId: contactX)
            ),
            ("digest-1790000000", "", "3 people are overdue: Ada, Grace, and Linus.", .digest),
        ]
    )
    func requestContentNeverCarriesAnIdentifier(
        identifier: String, title: String, body: String, kind: ReminderNotificationRequest.Kind
    ) throws {
        let now = try Self.utc(Self.now)
        let request = ReminderNotificationRequest(
            identifier: identifier, title: title, body: body,
            fireDate: now.addingTimeInterval(3600), kind: kind
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

    /// The system reads a trigger's components in the calendar they carry, or in
    /// the device's calendar when they carry none. A device set to the Buddhist
    /// or Japanese calendar would then read year 2026 as a year in that
    /// calendar's numbering and fire years off. `makeRequest` stores a Gregorian
    /// calendar in GMT in the components, whatever the device zone, and `decode`
    /// resolves in the same calendar.
    @Test("The trigger's components carry a Gregorian calendar in GMT, so any device calendar reads the same instant")
    func triggerComponentsCarryGregorianCalendarInGMT() throws {
        let now = try Self.utc(Self.now)
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))

        let mapped = UserNotificationsAdapter.makeRequest(
            Self.cadenceRequest(fireDate: now.addingTimeInterval(3 * 3600)), now: now, deviceZone: zone
        )

        let trigger = try #require(mapped.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.dateComponents.calendar?.identifier == .gregorian)
        #expect(trigger.dateComponents.calendar?.timeZone == .gmt)
    }

    /// Trigger components drop sub-second precision, so a fire date 0.4 s or
    /// 0.6 s ahead of a whole-second `now` names the second that is already
    /// `now`. A calendar trigger for that second never fires, so it must
    /// deliver immediately instead. The 0.4 and 0.6 offsets sit on either side
    /// of half a second, so rounding the fire date instead of truncating it
    /// fails 0.6.
    @Test("A fire date whose trigger instant is not after now delivers immediately", arguments: [-600.0, 0.0, 0.4, 0.6])
    func triggerInstantNotAfterNowDeliversImmediately(offsetFromNow: TimeInterval) throws {
        let now = try Self.utc(Self.now)
        let fireDate = now.addingTimeInterval(offsetFromNow)

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

    // MARK: Calendar edges

    /// A leap day and the year boundary, each with a device zone whose local
    /// date or year differs from GMT's at that instant, so a field read from
    /// the device calendar instead of GMT would show.
    @Test(
        "Leap-day and year-boundary fire dates round trip, and the trigger carries their GMT fields",
        arguments: [
            ("2028-02-29T00:00:00Z", "America/Los_Angeles", (2028, 2, 29, 0, 0, 0)),  // device date is Feb 28
            ("2028-02-29T12:00:00Z", "Pacific/Auckland", (2028, 2, 29, 12, 0, 0)),  // device date is Mar 1
            ("2027-12-31T23:59:59Z", "Pacific/Auckland", (2027, 12, 31, 23, 59, 59)),  // device year is 2028
            ("2028-01-01T00:00:00Z", "America/Los_Angeles", (2028, 1, 1, 0, 0, 0)),  // device year is 2027
        ]
    )
    func calendarEdgeFireDatesRoundTrip(
        fireDate: String, zone: String, fields: (Int, Int, Int, Int, Int, Int)
    ) throws {
        let mapped = try Self.expectGMTTrigger(zone: zone, fireDate: fireDate, fields: fields)

        #expect(UserNotificationsAdapter.decode(mapped) == Self.cadenceRequest(fireDate: try Self.utc(fireDate)))
    }

    // MARK: Foreground presentation

    @Test("A notification that arrives while Regards is in the foreground shows a banner, the list and sound")
    func willPresentShowsBannerListAndSound() {
        #expect(UserNotificationsAdapter.foregroundPresentationOptions == [.banner, .list, .sound])
    }

    private static let willPresentSelector = #selector(
        (any UNUserNotificationCenterDelegate).userNotificationCenter(_:willPresent:withCompletionHandler:)
    )

    /// Without this delegate method the system shows nothing for a notification
    /// that arrives in the foreground. The constant test above can't see the
    /// method being renamed or deleted, so this one checks it exists.
    @Test("The adapter implements the willPresent delegate method")
    func adapterImplementsWillPresent() {
        #expect(UserNotificationsAdapter.instancesRespond(to: Self.willPresentSelector))
    }

    /// `UNNotification` can't be constructed, so this calls the Objective-C
    /// implementation with nil for the center and the notification. It works
    /// because the method never reads them; if it starts to, this test crashes
    /// and the method needs a seam like `receive`.
    @Test("The willPresent delegate method completes with banner, list and sound")
    func willPresentCompletesWithBannerListAndSound() {
        typealias Implementation = @convention(c) (
            AnyObject, Selector, AnyObject?, AnyObject?, @convention(block) (UInt) -> Void
        ) -> Void
        let adapter = UserNotificationsAdapter()
        let call = unsafeBitCast(adapter.method(for: Self.willPresentSelector), to: Implementation.self)
        var completions: [UNNotificationPresentationOptions] = []

        call(adapter, Self.willPresentSelector, nil, nil) { completions.append(.init(rawValue: $0)) }

        #expect(completions == [[.banner, .list, .sound]])
    }

    // MARK: Helpers

    static var gmtCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    static func utc(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso), "unparseable test date \(iso)")
    }

    private static func cadenceRequest(fireDate: Date) -> ReminderNotificationRequest {
        ReminderNotificationRequest(
            identifier: "contact-\(contactX.uuidString)-cadence",
            title: "Time to reach out",
            body: "It has been a while since you talked to Ada.",
            fireDate: fireDate,
            kind: .cadence(contactId: contactX)
        )
    }

    static func request(_ category: NotificationCategory, fireDate: Date) -> ReminderNotificationRequest {
        switch category {
        case .cadence:
            return cadenceRequest(fireDate: fireDate)
        case .digest:
            return ReminderNotificationRequest(
                identifier: "digest-1790000000", title: "",
                body: "3 people are overdue: Ada, Grace, and Linus.",
                fireDate: fireDate, kind: .digest
            )
        case .occasion:
            return ReminderNotificationRequest(
                identifier: "contact-\(contactX.uuidString)-occasion", title: "Birthday",
                body: "It is Ada's birthday.", fireDate: fireDate, kind: .occasion(contactId: contactX)
            )
        }
    }

    /// Passes `makeRequest` `zone` as the device zone, then asserts the trigger
    /// names GMT, carries the fixed UTC wall-clock fields of `fireDate`, and
    /// reads back as exactly `fireDate`, both through its components and through
    /// `decode`. Given a `transition`, it first checks that it really is a DST
    /// transition of `zone`, so a tz database change fails here instead of
    /// silently testing a plain day. Returns the built request.
    @discardableResult
    private static func expectGMTTrigger(
        zone zoneIdentifier: String,
        transition: String? = nil,
        fireDate fireDateISO: String,
        fields: (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int),
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> UNNotificationRequest {
        let zone = try #require(TimeZone(identifier: zoneIdentifier), sourceLocation: sourceLocation)
        let fireDate = try utc(fireDateISO)
        let now = try utc(Self.now)
        if let transition {
            let transitionDate = try utc(transition)
            #expect(
                zone.nextDaylightSavingTimeTransition(after: transitionDate.addingTimeInterval(-1)) == transitionDate,
                "\(transition) is not a DST transition in \(zoneIdentifier)",
                sourceLocation: sourceLocation
            )
        }

        let mapped = UserNotificationsAdapter.makeRequest(
            cadenceRequest(fireDate: fireDate), now: now, deviceZone: zone
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
        #expect(UserNotificationsAdapter.decode(mapped)?.fireDate == fireDate, sourceLocation: sourceLocation)
        return mapped
    }
}
