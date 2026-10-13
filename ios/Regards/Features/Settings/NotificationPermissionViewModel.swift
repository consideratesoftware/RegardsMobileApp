import Foundation
import Observation
import SwiftUI
import UIKit

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
    /// True after the system request threw, so the tap didn't look dead. The
    /// row shows `requestFailedMessage` under it. Cleared when a later request
    /// succeeds or the status changes.
    public private(set) var requestFailed = false

    public static let requestFailedMessage = "Couldn't ask for notification permission. Try again."

    private let notifications: any NotificationScheduling
    /// Speaks a status change. Injected so a test can see what was said.
    private let announce: @MainActor (String) -> Void
    private var isRequesting = false
    private static let log = RegardsLogger.feature("NotificationPermission")

    public init(
        notifications: any NotificationScheduling,
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.notifications = notifications
        self.announce = announce
    }

    /// Reads the current status. Called when the screen appears.
    public func load() async {
        await refresh()
    }

    /// Re-reads the status. Called when the scene becomes active, so a change
    /// made in iOS Settings shows up on return.
    ///
    /// The row changes in place, so VoiceOver says nothing unless this does.
    /// It announces "Notifications on" or "Notifications off" when a status
    /// it already knew changes to authorized or denied. It stays silent on the
    /// first read and when the status is unchanged, including when another
    /// refresh already applied the change. Nothing announces a move
    /// back to `.notDetermined`: iOS doesn't do that while the app runs.
    public func refresh() async {
        let current = await notifications.authorizationStatus()
        // Read after the await, with no suspension before the write below. Two
        // overlapping refreshes (the request's own, and the scene turning
        // active when the system prompt closes) then see each other's result,
        // so only the first to apply a change announces it.
        let previous = status
        status = current
        guard let previous, previous != current else { return }
        requestFailed = false
        switch current {
        case .authorized: announce("Notifications on")
        case .denied: announce("Notifications off")
        case .notDetermined: break
        }
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
            requestFailed = false
        } catch {
            Self.log.error("notification authorization request failed: \(error, privacy: .private)")
            requestFailed = true
            announce(Self.requestFailedMessage)
        }
        await refresh()
    }

    /// Opens the Regards page in iOS Settings, where a denied permission can
    /// be changed. Lives here so the view holds no URL logic and a test can
    /// pass its own `OpenURLAction` and see the URL.
    public func openNotificationSettings(using openURL: OpenURLAction) {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        openURL(url)
    }
}
