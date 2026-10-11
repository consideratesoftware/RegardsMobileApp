import SwiftUI
import UIKit

enum RegardsSettingsRoute: Hashable {
    case reminderWindows
    case mergeDuplicates
    case transparency
    case onboarding
}

public struct SettingsScreen: View {
    /// Nil hides the Notifications section: a launch with no notification
    /// seam has nothing to show, and a row that did nothing would be inert.
    private let notifications: NotificationPermissionViewModel?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    public init(notifications: NotificationPermissionViewModel? = nil) {
        self.notifications = notifications
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                SectionHeader("Reminders")
                RegardsCard {
                    VStack(spacing: 0) {
                        navRow(
                            id: "reminder-windows",
                            title: "Reminder windows",
                            subtitle: "When it's OK to nudge you.",
                            route: .reminderWindows
                        )
                        Hair(inset: 16)
                        navRow(
                            id: "find-duplicate-contacts",
                            title: "Find duplicate contacts",
                            subtitle: "Virtual merges only.",
                            route: .mergeDuplicates
                        )
                    }
                }

                if let notifications, let status = notifications.status {
                    SectionHeader("Notifications")
                    RegardsCard {
                        notificationRow(status: status, viewModel: notifications)
                    }
                }

                SectionHeader("Privacy")
                RegardsCard {
                    navRow(
                        id: "transparency",
                        title: "Transparency",
                        subtitle: "How the privacy claim is verifiable.",
                        route: .transparency
                    )
                }

                SectionHeader("Help")
                RegardsCard {
                    navRow(
                        id: "onboarding-preview",
                        title: "Onboarding preview",
                        subtitle: "Revisit the permission intro.",
                        route: .onboarding
                    )
                }

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("screen.settings")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications?.load() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await notifications?.refresh() }
        }
        // The row changes in place, so VoiceOver would otherwise say nothing
        // after the prompt closes or the user returns from iOS Settings.
        .onChange(of: notifications?.status) { oldStatus, newStatus in
            guard oldStatus != nil, let newStatus else { return }
            AccessibilityNotification.Announcement(Self.notificationAnnouncement(for: newStatus)).post()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(RegardsDS.ink)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// `id` is an explicit stable accessibility identifier so the UI tests in
    /// `ScreensAccessibilityTests` don't silently break when copy tweaks.
    private func navRow(
        id: String,
        title: String,
        subtitle: String,
        route: RegardsSettingsRoute
    ) -> some View {
        NavigationLink(value: route) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(RegardsDS.ink)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(RegardsDS.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RegardsDS.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.\(id)")
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    // MARK: - Notifications row

    /// Copy describes the permission only. Nothing schedules a notification
    /// until TF-07, so none of it may promise reminders.
    private func notificationRow(
        status: NotificationAuthorizationStatus,
        viewModel: NotificationPermissionViewModel
    ) -> some View {
        Group {
            switch status {
            case .notDetermined:
                notificationButton(
                    title: "Turn on notifications",
                    subtitle: "iOS will ask whether Regards can show alerts and play sounds.",
                    hint: "iOS will ask whether Regards can show alerts and play sounds.",
                    icon: nil
                ) {
                    Task { await viewModel.requestAuthorization() }
                }
            case .denied:
                notificationButton(
                    title: "Open iOS Settings",
                    subtitle: "Notifications are off for Regards.",
                    hint: "Notifications are off for Regards. Opens the notification settings for Regards in iOS.",
                    icon: "arrow.up.forward.app"
                ) {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            case .authorized:
                notificationStatusRow(
                    title: "Notifications on",
                    subtitle: "Regards can show alerts and play sounds."
                )
            }
        }
    }

    private func notificationButton(
        title: String,
        subtitle: String,
        hint: String,
        icon: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                notificationText(title: title, subtitle: subtitle)
                Spacer()
                if let icon {
                    Image(systemName: icon)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(RegardsDS.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.notifications")
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    /// Plain text with no button trait: an authorized permission has nothing
    /// left to do, so a control here would be inert.
    private func notificationStatusRow(title: String, subtitle: String) -> some View {
        HStack {
            notificationText(title: title, subtitle: subtitle)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.notifications")
    }

    private func notificationText(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(RegardsDS.ink)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(RegardsDS.muted)
        }
    }

    private static func notificationAnnouncement(for status: NotificationAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "Notifications not set up"
        case .denied: "Notifications off"
        case .authorized: "Notifications on"
        }
    }
}
