import Foundation
import UserNotifications

// Request building and the scheduling members came back in TF-07e (R57). The
// adapter maps one `ReminderNotificationRequest` to one OS request and back.
// It decides nothing: `SchedulingPass` chooses what to schedule, the copy and
// the fire dates (§9a). Titles and bodies arrive as parameters and hold
// display names only. A contact id appears in the request identifier and in
// `userInfo`, never in visible text.

/// Permission state mirrored from `UNAuthorizationStatus`, so callers outside
/// the Platform layer never import UserNotifications.
public enum NotificationAuthorizationStatus: String, Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}

/// The notification shapes §9 contract 5 defines: one contact's cadence
/// reminder, a digest for every contact sharing a slot start, or an occasion
/// (birthday or anniversary). Occasions are never part of a digest.
public enum NotificationCategory: String, Sendable, Equatable, CaseIterable {
    case cadence = "regards.cadence"
    case digest = "regards.digest"
    case occasion = "regards.occasion"
}

/// A notification action the user took, decoded from the OS response.
public enum NotificationAction: Sendable, Equatable {
    case caughtUp(UUID)
    case snooze(UUID)
}

/// One OS notification to schedule. `fireDate` is the absolute instant
/// `SchedulingPass` resolved through the engine (§9); the adapter never
/// re-derives it from wall-clock fields in another zone.
public struct ReminderNotificationRequest: Sendable, Equatable {
    /// What the notification is. A cadence or occasion notification is about
    /// one contact and can't be built without its id. A cadence's Caught up
    /// and Snooze act on that contact; an occasion has no actions. A digest
    /// covers several contacts and carries none.
    public enum Kind: Equatable, Sendable {
        case cadence(contactId: UUID)
        case occasion(contactId: UUID)
        case digest
    }

    /// `contact-{uuid}-{kind}` or `digest-{slotStartEpoch}` (§9 contract 5).
    public let identifier: String
    /// Display names only. Never an identifier (privacy).
    public let title: String
    public let body: String
    public let fireDate: Date
    public let kind: Kind

    public var category: NotificationCategory {
        switch kind {
        case .cadence: return .cadence
        case .occasion: return .occasion
        case .digest: return .digest
        }
    }

    /// The contact a single-contact notification is about. Nil for a digest.
    public var contactId: UUID? {
        switch kind {
        case .cadence(let contactId), .occasion(let contactId): return contactId
        case .digest: return nil
        }
    }

    public init(
        identifier: String,
        title: String,
        body: String,
        fireDate: Date,
        kind: Kind
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.fireDate = fireDate
        self.kind = kind
    }
}

/// Seam over the system notification center (§9a). Production wires
/// `UserNotificationsAdapter.shared`; tests and the DEBUG mock launch inject
/// a fake so they never raise the system permission alert.
public protocol NotificationScheduling: Sendable {
    /// Raises the system prompt on first call; returns whether alerts are allowed.
    func requestAuthorization() async throws -> Bool
    func authorizationStatus() async -> NotificationAuthorizationStatus
    /// Actions the user takes on delivered notifications. Read it from one
    /// consumer only: a second concurrent iterator would take some of the
    /// actions and run alongside the first, so they'd be handled out of order.
    var actions: AsyncStream<NotificationAction> { get }
    /// The requests waiting to fire, decoded from the system's pending list.
    /// Content comes back, and the fire date comes back truncated to the whole
    /// second, so a caller can tell a moved or reworded request from an
    /// unchanged one under the same identifier. Every pending request is this
    /// app's (iOS keeps one list per app). A request
    /// `decode` can't read is left out; ARCHITECTURE.md §9a gives the rule for
    /// retiring or adding a request shape.
    func pendingRequests() async -> [ReminderNotificationRequest]
    /// Adds the request, or replaces a pending one with the same identifier.
    /// A `fireDate` that has already passed delivers at once (§9 contract 5).
    func schedule(_ request: ReminderNotificationRequest) async throws
    /// Removes pending requests. Unknown identifiers are ignored.
    func cancel(identifiers: [String]) async
}

/// Default `NotificationScheduling` backed by the system notification center.
///
/// Checked `Sendable` with no `@unchecked`: the class is final, inherits only
/// from `NSObject`, and stores two `let`s whose types are `Sendable`
/// (`AsyncStream` and its `Continuation` over a `Sendable` element). The
/// notification center is looked up per call rather than stored.
///
/// Production uses only `shared`. The system notification center keeps its
/// delegate weakly, so `shared` is the one instance that stays alive to
/// receive responses, and `actions` has a single consumer. A second adapter
/// would receive no responses. The initializer is internal for tests.
public final class UserNotificationsAdapter: NSObject, NotificationScheduling, UNUserNotificationCenterDelegate {
    public static let shared = UserNotificationsAdapter()

    public let actions: AsyncStream<NotificationAction>
    private let continuation: AsyncStream<NotificationAction>.Continuation

    private static let contactIdKey = "contactId"
    private static let caughtUpActionIdentifier = "regards.caught-up"
    private static let snoozeActionIdentifier = "regards.snooze"

    /// Internal so a test can build a fresh adapter; see the type's comment.
    override init() {
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

    public func pendingRequests() async -> [ReminderNotificationRequest] {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.compactMap(Self.decode)
    }

    public func schedule(_ request: ReminderNotificationRequest) async throws {
        // `Date()` is read here, once, immediately before the add, with no
        // early margin: a fire date that passes between planning and this
        // line gets no trigger and delivers now.
        let built = Self.makeRequest(request, now: Date())
        try await UNUserNotificationCenter.current().add(built)
    }

    public func cancel(identifiers: [String]) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// What a notification shows while Regards is in the foreground. Without
    /// the delegate method below, the system shows nothing.
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .list, .sound]

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.foregroundPresentationOptions)
    }

    /// `UNNotificationResponse` and its `userInfo` aren't `Sendable`, so the
    /// response is copied out here, synchronously, before anything leaves
    /// this method.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        receive(
            identifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo,
            completion: completionHandler
        )
    }

    /// Decodes a response and yields the action, if there is one. Only the
    /// `Sendable` `NotificationAction` crosses into the stream. Always calls
    /// `completion`, so the system is told the response was handled even when
    /// it decoded to nothing. Split out so a test can drive it without a
    /// `UNNotificationResponse`, which can't be constructed.
    func receive(identifier: String, userInfo: [AnyHashable: Any], completion: () -> Void) {
        if let action = Self.action(identifier: identifier, userInfo: userInfo) {
            continuation.yield(action)
        }
        completion()
    }

    // MARK: - Pure mapping (tested without the notification center)

    /// Builds the OS request. A future `fireDate` becomes a non-repeating
    /// `UNCalendarNotificationTrigger` (§9 platform nuance) whose components
    /// are pinned to UTC: UTC has no skipped or repeated hour, so the trigger
    /// names one absolute instant whatever the device zone or DST does. A
    /// request whose whole-second trigger instant is at or before `now` gets
    /// no trigger, which delivers immediately (§9 contract 5: a past slot
    /// start is an immediate delivery); a calendar trigger for a past instant
    /// would never fire.
    ///
    /// The visible text is `request.title` and `request.body` as given. The
    /// contact id goes to `userInfo` only.
    ///
    /// - Parameter now: read immediately before this request is added to the
    ///   center, once per request.
    static func makeRequest(
        _ request: ReminderNotificationRequest,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier = request.category.rawValue
        switch request.kind {
        case .cadence(let contactId), .occasion(let contactId):
            content.userInfo = [contactIdKey: contactId.uuidString]
        case .digest:
            break
        }

        // `calendar` carries the device zone; it is overwritten to GMT here.
        // Tests pass a DST-zone calendar to prove this line matters on any host.
        var utc = calendar
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

    /// The inverse of `makeRequest`, for a pending request. The fire date is
    /// read from the trigger's UTC components, so it doesn't depend on the
    /// current time or the device zone, and it has whole-second precision.
    /// Nil when the request isn't a shape this build leaves pending
    /// (ARCHITECTURE.md §9a). A cadence or occasion request with no valid
    /// contact id is one of those shapes, because `Kind` can't hold either
    /// without one. A cadence request's Caught up and Snooze would have
    /// nobody to act on.
    static func decode(_ request: UNNotificationRequest) -> ReminderNotificationRequest? {
        guard
            let trigger = request.trigger as? UNCalendarNotificationTrigger,
            let category = NotificationCategory(rawValue: request.content.categoryIdentifier)
        else {
            return nil
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let fireDate = utc.date(from: trigger.dateComponents) else {
            return nil
        }
        let contactId = (request.content.userInfo[contactIdKey] as? String).flatMap { UUID(uuidString: $0) }
        let kind: ReminderNotificationRequest.Kind
        switch category {
        case .cadence:
            guard let contactId else { return nil }
            kind = .cadence(contactId: contactId)
        case .occasion:
            guard let contactId else { return nil }
            kind = .occasion(contactId: contactId)
        case .digest:
            kind = .digest
        }
        return ReminderNotificationRequest(
            identifier: request.identifier,
            title: request.content.title,
            body: request.content.body,
            fireDate: fireDate,
            kind: kind
        )
    }

    /// Cadence notifications carry Caught up and Snooze 1 week; both open the
    /// app (owner ruling 2026-10-11, recorded in the PR #58 comment). There's
    /// no custom Open action: the OS default tap already opens the app, and an
    /// action that did nothing more would be an inert control (§10, R11).
    /// Digests and occasions carry no actions.
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
            UNNotificationCategory(
                identifier: NotificationCategory.occasion.rawValue,
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
