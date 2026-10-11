import Foundation
import Testing
import UserNotifications
@testable import Regards

private let contactX = UUID(uuidString: "5C1F0E52-8A3B-4D7E-9B1A-0C2D3E4F5A6B")!

/// TF-06 (§10, R11). Every assertion goes through the adapter's pure statics,
/// so no test touches the real notification center and none can raise the
/// system permission alert. The request-building and trigger tests return in
/// TF-07 with the code they cover (restore from fec13d7).
struct UserNotificationsAdapterTests {

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
}
