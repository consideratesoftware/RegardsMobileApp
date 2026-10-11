import Foundation
import UserNotifications

// R57 gate (ARCHITECTURE.md §19, owner ruling 2026-08-22): TF-06 must not
// ship notification scheduling. `SchedulingPass.snooze` writes `now + 7 days`
// without resolving the user's reminder window, so a notification scheduled
// from that row could fire outside the window, which §9 forbids. This file
// therefore carries permission and actions only: it builds no notification
// request and has no path that hands one to the system notification center.
// TF-07 restores request building plus `schedule`, `cancel`, and
// `pendingIdentifiers` in the PR that resolves R57.
//
// `NotificationSchedulingGateTests` enforces this on raw source text:
// G1, no other app file names the center type; G2, this file never
// contains the center's enqueue verb; G3, this file names the center type
// exactly 4 times (3 `.current()` calls and the delegate parameter).

/// Permission state mirrored from `UNAuthorizationStatus`, so callers outside
/// the Platform layer never import UserNotifications.
public enum NotificationAuthorizationStatus: String, Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}

/// The two notification shapes §9 contract 5 defines: one contact's cadence
/// reminder, or a digest for every contact sharing a slot start.
public enum NotificationCategory: String, Sendable, Equatable, CaseIterable {
    case cadence = "regards.cadence"
    case digest = "regards.digest"
}

/// A notification action the user took, decoded from the OS response.
public enum NotificationAction: Sendable, Equatable {
    case caughtUp(UUID)
    case snooze(UUID)
}

/// Seam over the system notification center (§9a). Production wires
/// `UserNotificationsAdapter.shared`; tests and the DEBUG mock launch inject
/// a fake so they never raise the system permission alert. TF-06 ships 3 of
/// §9a's members; `schedule`, `cancel`, and `pendingIdentifiers` arrive with
/// R57's fix in TF-07 (see the file header).
public protocol NotificationScheduling: Sendable {
    /// Raises the system prompt on first call; returns whether alerts are allowed.
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> NotificationAuthorizationStatus
    /// Actions the user takes on delivered notifications. Single consumer:
    /// a second concurrent iterator is a programmer error and traps.
    var actions: AsyncStream<NotificationAction> { get }
}

/// Default `NotificationScheduling` backed by the system notification center.
///
/// Checked `Sendable` with no `@unchecked`: the class is final, inherits only
/// from `NSObject`, and stores two `let`s whose types are `Sendable`
/// (`AsyncStream` and its `Continuation` over a `Sendable` element). The
/// notification center is looked up per call rather than stored.
///
/// Exactly one instance per process (`shared`), because the center holds its
/// delegate weakly and `actions` allows one consumer.
public final class UserNotificationsAdapter: NSObject, NotificationScheduling, UNUserNotificationCenterDelegate {
    public static let shared = UserNotificationsAdapter()

    public let actions: AsyncStream<NotificationAction>
    private let continuation: AsyncStream<NotificationAction>.Continuation

    private static let contactIdKey = "contactId"
    private static let caughtUpActionIdentifier = "regards.caught-up"
    private static let snoozeActionIdentifier = "regards.snooze"

    override private init() {
        // Unbounded: an action tapped on a cold launch arrives before the
        // consumer starts (it waits for the runtime), and user taps are few.
        (actions, continuation) = AsyncStream.makeStream(
            of: NotificationAction.self,
            bufferingPolicy: .unbounded
        )
        super.init()
    }

    /// Sets the delegate and registers categories. Call from `App.init()`:
    /// an action that launched the app is delivered to the delegate before
    /// launch finishes, so the delegate must already be set.
    public func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.categories)
    }

    // MARK: - NotificationScheduling

    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func authorizationStatus() async -> NotificationAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.status(from: settings.authorizationStatus)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// `UNNotificationResponse` and its `userInfo` aren't `Sendable`, so the
    /// response is decoded here, synchronously, and only the `Sendable`
    /// `NotificationAction` crosses into the stream.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = Self.action(
            identifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo
        )
        if let action {
            continuation.yield(action)
        }
        completionHandler()
    }

    // MARK: - Pure mapping (tested without the notification center)

    /// Cadence notifications carry Caught up and Snooze 1 week; both open the
    /// app (owner ruling 2026-10-11). There's no custom Open action: the OS
    /// default tap already opens the app, and an action that did nothing more
    /// would be an inert control (§10, R11). Digests carry no actions.
    static var categories: Set<UNNotificationCategory> {
        let caughtUp = UNNotificationAction(
            identifier: caughtUpActionIdentifier,
            title: "Caught up",
            options: [.foreground]
        )
        let snooze = UNNotificationAction(
            identifier: snoozeActionIdentifier,
            title: "Snooze 1 week",
            options: [.foreground]
        )
        return [
            UNNotificationCategory(
                identifier: NotificationCategory.cadence.rawValue,
                actions: [caughtUp, snooze],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: NotificationCategory.digest.rawValue,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
        ]
    }

    /// Decodes a response into an action. Nil for the default tap, dismiss,
    /// an unknown identifier, or a missing or malformed `contactId`.
    static func action(identifier: String, userInfo: [AnyHashable: Any]) -> NotificationAction? {
        guard let raw = userInfo[contactIdKey] as? String, let contactId = UUID(uuidString: raw) else {
            return nil
        }
        switch identifier {
        case caughtUpActionIdentifier: return .caughtUp(contactId)
        case snoozeActionIdentifier: return .snooze(contactId)
        default: return nil
        }
    }

    /// Provisional and ephemeral deliver notifications, so they count as
    /// authorized. An unknown future case maps to denied, which points the
    /// user at iOS Settings and never falsely shows notifications as on.
    static func status(from status: UNAuthorizationStatus) -> NotificationAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .denied
        }
    }
}
