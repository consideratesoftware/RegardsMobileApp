import Foundation
import UserNotifications

// R57 gate (ARCHITECTURE.md §19, owner ruling 2026-08-22): TF-06 ships this
// adapter with a working `schedule` and no production caller. Nothing may
// build a `ReminderNotificationRequest` from a `ScheduledReminder` row, and
// `SchedulingPass` takes no notification dependency, until TF-07 resolves
// R57. `NotificationSchedulingGateTests` fails the unit suite if app code
// outside `Platform/Notifications/` calls `.schedule(`, names
// `UNUserNotificationCenter`, or builds a `UNNotificationRequest(`.

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

/// One OS notification to schedule. `fireDate` is the absolute instant
/// SchedulingPass resolved through the engine (§9); the adapter never
/// re-derives it from wall-clock fields in another zone.
public struct ReminderNotificationRequest: Sendable, Equatable {
    /// `contact-{uuid}-{kind}` or `digest-{slotStartEpoch}` (§9 contract 5).
    public let identifier: String
    public let title: String
    public let body: String
    public let fireDate: Date
    /// Set for a single-contact notification, so its actions know whom they
    /// act on. Nil for a digest.
    public let contactId: UUID?
    public let category: NotificationCategory

    public init(
        identifier: String,
        title: String,
        body: String,
        fireDate: Date,
        contactId: UUID?,
        category: NotificationCategory
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.fireDate = fireDate
        self.contactId = contactId
        self.category = category
    }
}

/// Seam over `UNUserNotificationCenter` (§9a). Production wires
/// `UserNotificationsAdapter.shared`; tests and the DEBUG mock launch inject
/// a fake so they never raise the system permission alert.
public protocol NotificationScheduling: Sendable {
    /// Raises the system prompt on first call; returns whether alerts are allowed.
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func pendingIdentifiers() async -> Set<String>
    func schedule(_ requests: [ReminderNotificationRequest]) async throws
    func cancel(identifiers: [String]) async
    /// Actions the user takes on delivered notifications. Single consumer:
    /// a second concurrent iterator is a programmer error and traps.
    var actions: AsyncStream<NotificationAction> { get }
}

/// Default `NotificationScheduling` backed by `UNUserNotificationCenter`.
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

    public func pendingIdentifiers() async -> Set<String> {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Set(pending.map(\.identifier))
    }

    public func schedule(_ requests: [ReminderNotificationRequest]) async throws {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        for request in requests {
            try await center.add(Self.makeRequest(request, now: now))
        }
    }

    public func cancel(identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
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

    /// Builds the OS request. A future `fireDate` becomes a non-repeating
    /// `UNCalendarNotificationTrigger` (§9 platform nuance) whose components
    /// are pinned to UTC: UTC has no skipped or repeated hour, so the trigger
    /// names one absolute instant whatever the device zone or DST does. A
    /// `fireDate` at or before `now` gets a nil trigger, which delivers
    /// immediately (§9 contract 5: a past slot start is an immediate
    /// delivery); a calendar trigger for a past instant would never fire.
    static func makeRequest(_ request: ReminderNotificationRequest, now: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier = request.category.rawValue
        if let contactId = request.contactId {
            content.userInfo = [contactIdKey: contactId.uuidString]
        }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let components = utc.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: request.fireDate
        )
        // Components drop sub-second precision, so compare the instant the
        // trigger would actually name. If that has already passed, a calendar
        // trigger would never fire; deliver now instead.
        let trigger: UNCalendarNotificationTrigger?
        if let triggerInstant = utc.date(from: components), triggerInstant > now {
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            trigger = nil
        }

        return UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
    }

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
