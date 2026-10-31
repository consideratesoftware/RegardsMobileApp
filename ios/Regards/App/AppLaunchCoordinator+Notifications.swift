import Foundation

/// Notification actions (TF-06, ARCHITECTURE.md §9 re-evaluation triggers):
/// Caught up and Snooze 1 week tapped on a delivered cadence notification.
/// Split from `AppLaunchCoordinator.swift` to keep that file's primary type
/// body under the lint length limit, the same reason as the other two splits.
///
/// Runs on the main actor with the rest of the coordinator. The adapter's
/// delegate decodes the system response into a `Sendable`
/// `NotificationAction` before anything crosses an isolation boundary, so
/// nothing non-`Sendable` reaches this file.
extension AppLaunchCoordinator {
    /// Starts the single consumer of `notifications.actions`. `start()` calls
    /// this on every exit, once `phase` is decided (`.ready`, `.onboarding`,
    /// or `.failed`), so an action that launched the app (buffered in the
    /// stream until now) is judged against the real phase and never held
    /// across a failed launch. Idempotent: `retry()` reaches this again. A
    /// second iterator wouldn't trap; it would split actions between two tasks
    /// that run concurrently.
    func beginConsumingNotificationActions() {
        guard notificationActionTask == nil, let notifications else { return }
        let actions = notifications.actions
        notificationActionTask = Task { [weak self] in
            for await action in actions {
                guard let self else { return }
                await self.handleNotificationAction(action)
            }
        }
    }

    /// Applies one action. Dropped unless the tab root is showing: with no
    /// runtime (the launch-failure screen, or mid-`retry()`) no write could
    /// succeed, and during onboarding the user hasn't finished setting up.
    ///
    /// Known gap (PR22, closed by R10 in TF-07): Overdue and Upcoming don't
    /// observe `ScheduledReminder`, so a Snooze from a notification shows on
    /// their next `load()` rather than immediately.
    func handleNotificationAction(_ action: NotificationAction) async {
        // Counts every exit, dropped and ineligible included, after the
        // action's writes have finished.
        defer { recordHandledNotificationAction() }
        guard phase == .ready, let runtime else {
            Self.notificationLog.info("dropped a notification action: the app isn't ready")
            return
        }
        switch action {
        case .caughtUp(let contactId):
            do {
                // The pass checks eligibility itself, on the read its writes
                // use, and returns false rather than writing for a contact
                // the notification outlived.
                let logged = try await runtime.scheduler.recordInteraction(
                    contactId: contactId,
                    .caughtUpFromNotification
                )
                if !logged {
                    Self.notificationLog.info("ignored Caught up from a notification for an ineligible contact")
                }
            } catch {
                Self.notificationLog.error("Caught up from a notification failed: \(error, privacy: .private)")
            }
        case .snooze(let contactId):
            do {
                // `snooze` checks tracked, cadence, and active itself and
                // returns false rather than writing for anyone else.
                let wrote = try await runtime.scheduler.snooze(contactId: contactId)
                if !wrote {
                    Self.notificationLog.info("ignored Snooze from a notification for an ineligible contact")
                }
            } catch {
                Self.notificationLog.error("Snooze from a notification failed: \(error, privacy: .private)")
            }
        }
    }

    private static let notificationLog = RegardsLogger.feature("AppLaunchCoordinator")
}
