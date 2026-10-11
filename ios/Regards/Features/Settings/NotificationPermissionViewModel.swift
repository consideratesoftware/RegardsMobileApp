import Foundation
import Observation

/// State behind the Settings notifications row (§10 item 7). The row has
/// three states, one per `NotificationAuthorizationStatus`, and only the
/// undecided one can raise the system prompt.
///
/// TF-06 ships the permission only; nothing schedules a notification until
/// TF-07, so nothing here or in the row's copy may imply reminders are
/// coming. TF-11 reuses this view model for the onboarding step.
///
/// `status` stays nil until the first read, so the row never flashes a state
/// the system hasn't confirmed.
@Observable @MainActor
public final class NotificationPermissionViewModel {
    public private(set) var status: NotificationAuthorizationStatus?

    private let notifications: any NotificationScheduling
    private var isRequesting = false
    private static let log = RegardsLogger.feature("NotificationPermission")

    public init(notifications: any NotificationScheduling) {
        self.notifications = notifications
    }

    /// Reads the current status. Called when the screen appears.
    public func load() async {
        await refresh()
    }

    /// Re-reads the status. Called when the scene becomes active, so a change
    /// made in iOS Settings shows up on return.
    public func refresh() async {
        status = await notifications.authorizationStatus()
    }

    /// Raises the system prompt, but only from a known `.notDetermined`.
    /// iOS never re-prompts once the user has decided, so a request in any
    /// other state would only look like a control that does nothing.
    ///
    /// The outcome is read back from the system instead of trusting the
    /// result, so a throw and a decline both land on whatever iOS says.
    public func requestAuthorization() async {
        guard status == .notDetermined, !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        do {
            _ = try await notifications.requestAuthorization()
        } catch {
            Self.log.error("notification authorization request failed: \(error, privacy: .private)")
        }
        await refresh()
    }
}
