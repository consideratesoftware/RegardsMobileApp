import SwiftUI

enum RegardsSettingsRoute: Hashable {
    case reminderWindows
    case mergeDuplicates
    case transparency
    case starterContacts
}

public struct SettingsScreen: View {
    /// Nil hides the Notifications section: a launch with no notification
    /// seam has nothing to show, and a row that did nothing would be inert.
    private let notifications: NotificationPermissionViewModel?
    /// Nil hides the Contacts access row: a launch with no Contacts source
    /// (the DEBUG mock runtime) has nothing to show.
    private let contactsAccess: ContactsAccessViewModel?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AccessibilityFocusState private var notificationRowFocused: Bool
    @AccessibilityFocusState private var contactsRowFocused: Bool
    /// Whether this screen is showing. The status can change while a pushed
    /// screen covers it, and focus must not move on a screen the user isn't on.
    @State private var isOnScreen = false

    public init(notifications: NotificationPermissionViewModel?, contactsAccess: ContactsAccessViewModel? = nil) {
        self.notifications = notifications
        self.contactsAccess = contactsAccess
    }

    // MARK: - Body

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

                SectionHeader("People")
                RegardsCard {
                    VStack(spacing: 0) {
                        if let contactsAccess {
                            ContactsAccessRow(viewModel: contactsAccess, isFocused: $contactsRowFocused)
                        }
                        navRow(
                            id: "choose-starters",
                            title: "Choose people to keep in touch with",
                            subtitle: "Pick up to 3, and how often.",
                            route: .starterContacts
                        )
                    }
                }

                if let notifications, let status = notifications.status {
                    SectionHeader("Notifications")
                    RegardsCard {
                        // Copy describes the permission only. Nothing
                        // schedules a notification until TF-07, so none of it
                        // may promise reminders. Each state is written out:
                        // they differ in button trait, icon, and VoiceOver
                        // label.
                        switch status {
                        case .notDetermined:
                            Button {
                                Task { await notifications.requestAuthorization() }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Turn on notifications")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(RegardsDS.ink)
                                        Text("iOS will ask whether Regards can show alerts and play sounds.")
                                            .font(.footnote)
                                            .foregroundStyle(RegardsDS.muted)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityFocused($notificationRowFocused)
                            .accessibilityIdentifier("settings.notifications")
                            .accessibilityLabel("Turn on notifications")
                            .accessibilityHint("iOS will ask whether Regards can show alerts and play sounds.")
                        case .denied:
                            Button {
                                notifications.openNotificationSettings(using: openURL)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Open iOS Settings")
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(RegardsDS.ink)
                                        Text("Notifications are off for Regards.")
                                            .font(.footnote)
                                            .foregroundStyle(RegardsDS.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.up.forward.app")
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
                            .accessibilityFocused($notificationRowFocused)
                            .accessibilityIdentifier("settings.notifications")
                            // The state is in the label, not only the hint, so
                            // it is heard with hints turned off.
                            .accessibilityLabel("Notifications off. Open iOS Settings")
                            .accessibilityHint("Opens the notification settings for Regards in iOS.")
                        case .authorized:
                            // Plain text with no button trait: an authorized
                            // permission has nothing left to do, so a control
                            // here would be inert.
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Notifications on")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(RegardsDS.ink)
                                    Text("Regards can show alerts and play sounds.")
                                        .font(.footnote)
                                        .foregroundStyle(RegardsDS.muted)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(minHeight: 44)
                            .accessibilityElement(children: .combine)
                            .accessibilityFocused($notificationRowFocused)
                            .accessibilityIdentifier("settings.notifications")
                        }
                    }
                    if notifications.requestFailed {
                        Text(NotificationPermissionViewModel.requestFailedMessage)
                            .font(.footnote)
                            .foregroundStyle(RegardsDS.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .accessibilityIdentifier("settings.notifications.error")
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

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("screen.settings")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .task { await notifications?.load() }
        .task { await contactsAccess?.load() }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await notifications?.refresh() }
            Task { await contactsAccess?.refresh() }
        }
        // The row is replaced when the status changes (the button becomes
        // status text, or another button), which drops VoiceOver focus from
        // it. Move focus to the new row so the result is heard even if the
        // announcement is cut off. The yield lets the new row reach the
        // accessibility tree first. Not on the first read.
        .onChange(of: notifications?.status) { oldStatus, newStatus in
            guard isOnScreen, oldStatus != nil, newStatus != nil else { return }
            notificationRowFocused = false
            Task { @MainActor in
                await Task.yield()
                notificationRowFocused = true
            }
        }
        // Same for the Contacts row, which swaps its button for status text.
        .onChange(of: contactsAccess?.status) { oldStatus, newStatus in
            guard isOnScreen, oldStatus != nil, newStatus != nil else { return }
            contactsRowFocused = false
            Task { @MainActor in
                await Task.yield()
                contactsRowFocused = true
            }
        }
    }

    // MARK: - Header and rows

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
}
