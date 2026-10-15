import Foundation
import Testing
import UserNotifications
@testable import Regards

private let contactX = UUID(uuidString: "5C1F0E52-8A3B-4D7E-9B1A-0C2D3E4F5A6B")!

/// TF-06 (§10, R11). Most assertions go through the adapter's pure statics
/// (categories, decoding, status mapping). The `receive` tests build a fresh
/// `UserNotificationsAdapter()` and read its `actions` stream, which is also
/// free of the system notification center. Neither touches the real center, so
/// none can raise the system permission alert. The request-building and
/// trigger tests return in TF-07 with the code they cover (restore from
/// fec13d7).
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

    // MARK: Delegate seam

    /// `receive` is what the notification center's delegate method calls once
    /// it has copied the response apart, so the yield-and-complete behavior is
    /// testable without a `UNNotificationResponse`, which can't be built.
    @Test("A decoded response is yielded as an action and the completion runs once")
    func receiveYieldsDecodedActionAndCallsCompletion() async {
        let adapter = UserNotificationsAdapter()
        var completions = 0

        adapter.receive(identifier: "regards.snooze", userInfo: ["contactId": contactX.uuidString]) {
            completions += 1
        }

        #expect(await Self.firstBufferedAction(of: adapter) == .snooze(contactX))
        #expect(completions == 1)
    }

    @Test(
        "A default tap or an undecodable response yields nothing but still runs the completion",
        arguments: [
            (UNNotificationDefaultActionIdentifier, contactX.uuidString as String?),
            ("regards.caught-up", nil),
            ("regards.snooze", "not-a-uuid"),
        ]
    )
    func receiveOfUndecodableResponseYieldsNothingButCompletes(identifier: String, contactId: String?) async {
        let adapter = UserNotificationsAdapter()
        var userInfo: [AnyHashable: Any] = [:]
        if let contactId { userInfo["contactId"] = contactId }
        var completions = 0

        adapter.receive(identifier: identifier, userInfo: userInfo) { completions += 1 }
        // A real action sent next arrives first only if the first yielded nothing.
        adapter.receive(identifier: "regards.caught-up", userInfo: ["contactId": contactX.uuidString]) {
            completions += 1
        }

        #expect(await Self.firstBufferedAction(of: adapter) == .caughtUp(contactX))
        #expect(completions == 2)
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

    /// The first action `receive` has already yielded, or nil if it yielded
    /// none. `receive` yields synchronously into an unbounded buffer, so the
    /// reader is cancelled at once: a buffered action is still returned, and
    /// an empty stream ends the read instead of hanging the test. This relies
    /// on `AsyncStream` handing an already-buffered element to an iterator whose
    /// task was cancelled before its first `next()`; the tests passing is the
    /// evidence that it does.
    private static func firstBufferedAction(of adapter: UserNotificationsAdapter) async -> NotificationAction? {
        let stream = adapter.actions
        let reader = Task { () -> NotificationAction? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        reader.cancel()
        return await reader.value
    }
}
