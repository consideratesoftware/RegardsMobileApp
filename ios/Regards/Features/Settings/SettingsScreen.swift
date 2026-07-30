import SwiftUI

enum RegardsSettingsRoute: Hashable {
    case reminderWindows
    case mergeDuplicates
    case transparency
    case onboarding
}

public struct SettingsScreen: View {
    public init() {}

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
                            subtitle: "when it's OK to nudge you",
                            route: .reminderWindows
                        )
                        Hair(inset: 16)
                        navRow(
                            id: "find-duplicate-contacts",
                            title: "Find duplicate contacts",
                            subtitle: "virtual merges only",
                            route: .mergeDuplicates
                        )
                    }
                }

                SectionHeader("Privacy")
                RegardsCard {
                    navRow(
                        id: "transparency",
                        title: "Transparency",
                        subtitle: "how the privacy claim is verifiable",
                        route: .transparency
                    )
                }

                SectionHeader("Help")
                RegardsCard {
                    navRow(
                        id: "onboarding-preview",
                        title: "Onboarding preview",
                        subtitle: "revisit the permission intro",
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
}
