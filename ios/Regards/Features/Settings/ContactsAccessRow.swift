import SwiftUI

/// The Settings "Contacts access" row (TF-11), in the same card as "Choose
/// people to keep in touch with". Renders nothing until the first status read,
/// so `SettingsScreen` can always include it. Each state is written out: they
/// differ in button trait, icon, and VoiceOver label.
struct ContactsAccessRow: View {
    let viewModel: ContactsAccessViewModel
    var isFocused: AccessibilityFocusState<Bool>.Binding
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let status = viewModel.status {
            VStack(spacing: 0) {
                switch status {
                case .notDetermined:
                    Button {
                        Task { await viewModel.requestAccess() }
                    } label: {
                        text("Allow Contacts access", "iOS will ask whether Regards can read your contacts.")
                    }
                    .buttonStyle(.plain)
                    .accessibilityFocused(isFocused)
                    .accessibilityIdentifier("settings.contacts-access")
                    .accessibilityLabel("Allow Contacts access")
                    .accessibilityHint("iOS will ask whether Regards can read your contacts.")
                case .denied, .restricted:
                    Button {
                        viewModel.openContactsSettings(using: openURL)
                    } label: {
                        text("Open iOS Settings", "Contacts access is off for Regards.", showsArrow: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityFocused(isFocused)
                    .accessibilityIdentifier("settings.contacts-access")
                    // The state is in the label, not only the hint, so it is
                    // heard with hints turned off.
                    .accessibilityLabel("Contacts access off. Open iOS Settings")
                    .accessibilityHint(
                        "Opens the settings for Regards in iOS. Regards imports your contacts when you come back."
                    )
                case .authorized:
                    // Plain text with no button trait: nothing is left to do,
                    // so a control here would be inert.
                    text("Contacts access on", "Regards can read your contacts.")
                        .accessibilityElement(children: .combine)
                        .accessibilityFocused(isFocused)
                        .accessibilityIdentifier("settings.contacts-access")
                case .limited:
                    text("Contacts access limited", "Regards can read only the contacts you shared.")
                        .accessibilityElement(children: .combine)
                        .accessibilityFocused(isFocused)
                        .accessibilityIdentifier("settings.contacts-access")
                }
                if viewModel.requestFailed {
                    Text(ContactsAccessViewModel.requestFailedMessage)
                        .font(.footnote)
                        .foregroundStyle(RegardsDS.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .accessibilityIdentifier("settings.contacts-access.error")
                }
                Hair(inset: 16)
            }
        }
    }

    private func text(_ title: String, _ subtitle: String, showsArrow: Bool = false) -> some View {
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
            if showsArrow {
                Image(systemName: "arrow.up.forward.app")
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
}
