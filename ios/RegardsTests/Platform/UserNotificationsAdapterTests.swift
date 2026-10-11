import Foundation
import Testing
import UserNotifications
@testable import Regards

private let contactX = UUID(uuidString: "5C1F0E52-8A3B-4D7E-9B1A-0C2D3E4F5A6B")!

/// TF-06 (§9 platform nuance, §9 contract 5, R57). Every assertion goes
/// through the adapter's pure statics, so no test touches the real
/// `UNUserNotificationCenter` and none can raise the system permission alert.
///
/// The DST tests never change `NSTimeZone.default`: Swift Testing runs suites
/// in parallel, and several other suites read the default zone implicitly.
/// They pass `makeRequest` a gregorian calendar set to a zone with a real DST
/// transition (the calendar carries the device zone), find that transition at
/// run time, and assert two things about the trigger: it fires at the exact
/// instant, and the zone it names has the same offset on both sides of the
/// transition. Deleting the adapter's pin to GMT fails the offset check on
/// every host, including a UTC CI runner.
///
/// `nextTriggerDate()` is relative to the real current time and the
/// calendar trigger has no injectable clock, so tests that call it must pick
/// a `fireDate` after the real `Date()`. They capture one `now` and derive the
/// fire date from it; that is the only use of the wall clock in this file.
struct UserNotificationsAdapterTests {

    // MARK: Request mapping

    @Test("A cadence request keeps its identifier, title, body, category and contact id")
    func requestCarriesIdentifierContentCategoryAndContactId() {
        let now = Self.wholeSeconds(Date())
        let request = Self.cadenceRequest(fireDate: now.addingTimeInterval(3 * 3600))

        let mapped = UserNotificationsAdapter.makeRequest(request, now: now)

        #expect(mapped.identifier == "contact-\(contactX.uuidString)-cadence")
        #expect(mapped.content.title == "Time to reach out")
        #expect(mapped.content.body == "It has been a while since you talked to Ada.")
        #expect(mapped.content.categoryIdentifier == "regards.cadence")
        #expect(mapped.content.userInfo["contactId"] as? String == contactX.uuidString)
    }

    @Test("A digest request carries the digest category and no contact id")
    func digestRequestCarriesDigestCategoryWithoutContactId() {
        let now = Self.wholeSeconds(Date())
        let request = ReminderNotificationRequest(
            identifier: "digest-2026-10-12",
            title: "3 people to catch up with",
            body: "Ada, Grace and Linus are due.",
            fireDate: now.addingTimeInterval(3 * 3600),
            contactId: nil,
            category: .digest
        )

        let mapped = UserNotificationsAdapter.makeRequest(request, now: now)

        #expect(mapped.identifier == "digest-2026-10-12")
        #expect(mapped.content.categoryIdentifier == "regards.digest")
        #expect(mapped.content.userInfo["contactId"] == nil)
    }

    // MARK: Trigger instant

    @Test("A future fire date maps to a non-repeating calendar trigger that fires at that instant")
    func futureFireDateUsesNonRepeatingCalendarTrigger() throws {
        let now = Self.wholeSeconds(Date())
        let fireDate = now.addingTimeInterval(3 * 3600)

        let mapped = UserNotificationsAdapter.makeRequest(Self.cadenceRequest(fireDate: fireDate), now: now)

        let trigger = try #require(mapped.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats == false)
        #expect(trigger.nextTriggerDate() == fireDate)
    }

    @Test("A fire date at or before now maps to no trigger, which delivers immediately", arguments: [-600.0, 0.0])
    func pastOrPresentFireDateDeliversImmediately(offsetFromNow: TimeInterval) {
        let now = Self.wholeSeconds(Date())
        let fireDate = now.addingTimeInterval(offsetFromNow)

        let mapped = UserNotificationsAdapter.makeRequest(Self.cadenceRequest(fireDate: fireDate), now: now)

        #expect(mapped.trigger == nil)
    }

    /// Trigger components drop sub-second precision, so a fire date 0.4 s
    /// ahead of a whole-second `now` names the second that is already `now`.
    /// A calendar trigger for that second never fires, so it must deliver
    /// immediately instead.
    @Test("A trigger instant (fire date truncated to the second) not after now maps to no trigger")
    func triggerInstantNotAfterNowDeliversImmediately() {
        let now = Self.wholeSeconds(Date())
        let fireDate = now.addingTimeInterval(0.4)

        let mapped = UserNotificationsAdapter.makeRequest(Self.cadenceRequest(fireDate: fireDate), now: now)

        #expect(mapped.trigger == nil)
    }

    /// The other side of the boundary: one whole second ahead is still a
    /// future instant. It doesn't call `nextTriggerDate()`, because the real
    /// clock may pass that second before the assertion runs.
    @Test("A trigger instant one second after now gets a calendar trigger")
    func triggerInstantOneSecondAfterNowGetsCalendarTrigger() throws {
        let now = Self.wholeSeconds(Date())
        let fireDate = now.addingTimeInterval(1.0)

        let mapped = UserNotificationsAdapter.makeRequest(Self.cadenceRequest(fireDate: fireDate), now: now)

        let trigger = try #require(mapped.trigger as? UNCalendarNotificationTrigger)
        #expect(trigger.repeats == false)
    }

    // MARK: DST (§13)

    @Test("Fall-back: 30 minutes after the repeated hour begins fires at the second occurrence, not an hour early")
    func triggerHitsSecondOccurrenceOfRepeatedHour() throws {
        try Self.expectTriggerInstant(
            zoneIdentifier: "America/Los_Angeles", springForward: false, secondsAfterTransition: 30 * 60
        )
    }

    @Test("Spring-forward: 15 minutes after the skipped hour fires at that exact instant")
    func triggerAcrossSpringForward() throws {
        try Self.expectTriggerInstant(
            zoneIdentifier: "America/New_York", springForward: true, secondsAfterTransition: 15 * 60
        )
    }

    @Test("A 30-minute DST shift in Lord Howe fires at the exact instant in both directions", arguments: [true, false])
    func triggerAcrossLordHoweHalfHourShift(springForward: Bool) throws {
        try Self.expectTriggerInstant(
            zoneIdentifier: "Australia/Lord_Howe", springForward: springForward, secondsAfterTransition: 15 * 60
        )
    }

    // MARK: Categories

    @Test("Registered categories are cadence with Caught up and Snooze (both foreground) and an empty digest")
    func categoriesMatchActionContract() throws {
        let categories = UserNotificationsAdapter.categories
        #expect(Set(categories.map(\.identifier)) == ["regards.cadence", "regards.digest"])

        let cadence = try #require(categories.first { $0.identifier == "regards.cadence" })
        #expect(Set(cadence.actions.map(\.identifier)) == ["regards.caught-up", "regards.snooze"])
        #expect(cadence.actions.count == 2)
        let caughtUp = try #require(cadence.actions.first { $0.identifier == "regards.caught-up" })
        let snooze = try #require(cadence.actions.first { $0.identifier == "regards.snooze" })
        #expect(caughtUp.title == "Caught up")
        #expect(snooze.title == "Snooze 1 week")
        #expect(caughtUp.options == [.foreground])
        #expect(snooze.options == [.foreground])

        let digest = try #require(categories.first { $0.identifier == "regards.digest" })
        #expect(digest.actions.isEmpty)
    }

    // MARK: Decoding

    @Test(
        "Caught up and Snooze identifiers decode to the matching action for the contact",
        arguments: [
            ("regards.caught-up", NotificationAction.caughtUp(contactX)),
            ("regards.snooze", NotificationAction.snooze(contactX)),
        ]
    )
    func decodesCaughtUpAndSnooze(identifier: String, expected: NotificationAction) {
        let userInfo: [AnyHashable: Any] = ["contactId": contactX.uuidString]

        #expect(UserNotificationsAdapter.action(identifier: identifier, userInfo: userInfo) == expected)
    }

    @Test(
        "Default tap, dismiss, unknown identifiers, and a missing or malformed contact id decode to nothing",
        arguments: [
            (UNNotificationDefaultActionIdentifier, contactX.uuidString as String?),
            (UNNotificationDismissActionIdentifier, contactX.uuidString as String?),
            ("regards.unknown", contactX.uuidString as String?),
            ("regards.caught-up", nil),
            ("regards.snooze", nil),
            ("regards.caught-up", "not-a-uuid"),
            ("regards.snooze", "not-a-uuid"),
        ]
    )
    func ignoresDefaultDismissUnknownMissingAndMalformed(identifier: String, contactId: String?) {
        var userInfo: [AnyHashable: Any] = [:]
        if let contactId { userInfo["contactId"] = contactId }

        #expect(UserNotificationsAdapter.action(identifier: identifier, userInfo: userInfo) == nil)
    }

    @Test("A contact id that is not a string decodes to nothing")
    func nonStringContactIdIsIgnored() {
        let userInfo: [AnyHashable: Any] = ["contactId": 42]

        #expect(UserNotificationsAdapter.action(identifier: "regards.caught-up", userInfo: userInfo) == nil)
    }

    @Test("The user info a request is built with decodes back to the same contact for both actions")
    func requestUserInfoRoundTripsThroughDecoder() {
        let now = Self.wholeSeconds(Date())
        let mapped = UserNotificationsAdapter.makeRequest(
            Self.cadenceRequest(fireDate: now.addingTimeInterval(3600)), now: now
        )
        let userInfo = mapped.content.userInfo

        #expect(UserNotificationsAdapter.action(identifier: "regards.caught-up", userInfo: userInfo)
            == .caughtUp(contactX))
        #expect(UserNotificationsAdapter.action(identifier: "regards.snooze", userInfo: userInfo)
            == .snooze(contactX))
    }

    // MARK: Authorization status

    @Test(
        "Every system authorization status maps to the app's three states, with unknown values never shown as on",
        arguments: [
            (UNAuthorizationStatus.notDetermined, NotificationAuthorizationStatus.notDetermined),
            (UNAuthorizationStatus.denied, NotificationAuthorizationStatus.denied),
            (UNAuthorizationStatus.authorized, NotificationAuthorizationStatus.authorized),
            (UNAuthorizationStatus.provisional, NotificationAuthorizationStatus.authorized),
            (UNAuthorizationStatus.ephemeral, NotificationAuthorizationStatus.authorized),
        ]
    )
    func authorizationStatusMapsEveryCase(
        system: UNAuthorizationStatus, expected: NotificationAuthorizationStatus
    ) {
        #expect(UserNotificationsAdapter.status(from: system) == expected)
    }

    @Test("A status value the SDK adds later maps to denied")
    func unknownAuthorizationStatusMapsToDenied() throws {
        let future = try #require(UNAuthorizationStatus(rawValue: 99))

        #expect(UserNotificationsAdapter.status(from: future) == .denied)
    }

    // MARK: Helpers

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

    private static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// The first DST transition after `start` in `zone` whose direction
    /// matches. `nextDaylightSavingTimeTransition` alone returns whichever
    /// comes next, so a fixed spring-forward or fall-back test needs this
    /// scan. Computing it at run time means the test never goes stale.
    private static func nextTransition(in zone: TimeZone, springForward: Bool, after start: Date) -> Date? {
        var cursor = start
        for _ in 0..<8 {
            guard let transition = zone.nextDaylightSavingTimeTransition(after: cursor) else { return nil }
            let before = zone.daylightSavingTimeOffset(for: transition.addingTimeInterval(-1))
            let after = zone.daylightSavingTimeOffset(for: transition.addingTimeInterval(1))
            if (after > before) == springForward { return transition }
            cursor = transition
        }
        return nil
    }

    /// Builds a request firing `secondsAfterTransition` after the next DST
    /// transition of the given direction in `zoneIdentifier` (passed as the
    /// device calendar, so the result doesn't depend on the host zone), then asserts
    /// that the trigger's next fire instant is exactly that absolute instant
    /// and that the zone the trigger names has no offset change across the
    /// transition.
    private static func expectTriggerInstant(
        zoneIdentifier: String,
        springForward: Bool,
        secondsAfterTransition: TimeInterval,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let zone = try #require(TimeZone(identifier: zoneIdentifier), sourceLocation: sourceLocation)
        let now = wholeSeconds(Date())
        let transition = try #require(
            nextTransition(in: zone, springForward: springForward, after: now),
            "no \(springForward ? "spring-forward" : "fall-back") transition found for \(zoneIdentifier)",
            sourceLocation: sourceLocation
        )
        let fireDate = wholeSeconds(transition.addingTimeInterval(secondsAfterTransition))

        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = zone
        let mapped = UserNotificationsAdapter.makeRequest(
            cadenceRequest(fireDate: fireDate), now: now, calendar: deviceCalendar
        )

        let trigger = try #require(mapped.trigger as? UNCalendarNotificationTrigger, sourceLocation: sourceLocation)
        #expect(trigger.nextTriggerDate() == fireDate, sourceLocation: sourceLocation)

        let triggerZone = try #require(trigger.dateComponents.timeZone, sourceLocation: sourceLocation)
        let offsetBefore = triggerZone.secondsFromGMT(for: transition.addingTimeInterval(-1))
        let offsetAfter = triggerZone.secondsFromGMT(for: transition.addingTimeInterval(1))
        #expect(
            offsetBefore == offsetAfter,
            "trigger zone \(triggerZone.identifier) shifts across the \(zoneIdentifier) transition",
            sourceLocation: sourceLocation
        )
    }
}
