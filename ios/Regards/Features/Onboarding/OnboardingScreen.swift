import SwiftUI

/// Pre-permission-prompt onboarding (screen-misc.jsx::OnboardingScreen).
public struct OnboardingScreen: View {
    private enum RecoveryAction: Hashable {
        case allowContacts
        case continueWithoutContacts
    }

    @AccessibilityFocusState private var focusedRecoveryAction: RecoveryAction?

    let showsPermissionAction: Bool
    let isBusy: Bool
    let statusMessage: String?
    let canContinueWithoutContacts: Bool
    let onAllow: () -> Void
    let onContinueWithoutContacts: (() -> Void)?
    let onWhyWeAsk: () -> Void

    public init(showsPermissionAction: Bool = true,
                isBusy: Bool = false,
                statusMessage: String? = nil,
                canContinueWithoutContacts: Bool = false,
                onAllow: @escaping () -> Void = {},
                onContinueWithoutContacts: (() -> Void)? = nil,
                onWhyWeAsk: @escaping () -> Void = {}) {
        self.showsPermissionAction = showsPermissionAction
        self.isBusy = isBusy
        self.statusMessage = statusMessage
        self.canContinueWithoutContacts = canContinueWithoutContacts
        self.onAllow = onAllow
        self.onContinueWithoutContacts = onContinueWithoutContacts
        self.onWhyWeAsk = onWhyWeAsk
    }

    public var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    wordmarkHeader
                        .padding(.top, proxy.safeAreaInsets.top + 24)

                    avatarCluster
                        .padding(.top, 40)
                        .padding(.bottom, 40)

                    pitch

                    permissionBullets
                        .padding(.top, 24)
                        .padding(.horizontal, 24)

                    if showsPermissionAction {
                        allowButton
                            .padding(.top, 20)
                            .padding(.horizontal, 24)
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(RegardsDS.muted)
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                            .padding(.horizontal, 28)
                            .accessibilityIdentifier("onboarding.status")
                    }

                    if canContinueWithoutContacts, let onContinueWithoutContacts {
                        Button("Continue without contacts", action: onContinueWithoutContacts)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(RegardsDS.accentInk)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .padding(.top, 4)
                            .disabled(isBusy)
                            .accessibilityFocused(
                                $focusedRecoveryAction,
                                equals: .continueWithoutContacts
                            )
                            .accessibilityIdentifier("onboarding.continue-without-contacts")
                    }

                    Button("Why we ask · read the proofs", action: onWhyWeAsk)
                        .font(.subheadline.weight(.medium))
                        // Sibling to the "Allow contacts access" CTA above —
                        // body-sized tappable text, so `accentInk` for AA
                        // against the light background.
                        .foregroundStyle(RegardsDS.accentInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .padding(.top, 4)
                        .disabled(isBusy)
                        .accessibilityIdentifier("onboarding.why-we-ask")

                    Color.clear.frame(height: 40)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .accessibilityIdentifier("screen.onboarding")
        .onChange(of: statusMessage) { _, message in
            guard let message else { return }
            AccessibilityNotification.Announcement(message).post()
            Task { @MainActor in
                await Task.yield()
                focusedRecoveryAction = canContinueWithoutContacts
                    ? .continueWithoutContacts
                    : .allowContacts
            }
        }
    }

    private var wordmarkHeader: some View {
        VStack(spacing: 10) {
            Wordmark(size: 48)
            Text("Keep your people in your regards".uppercased())
                .font(.caption2.weight(.medium))
                .kerning(1.5)
                .foregroundStyle(RegardsDS.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var avatarCluster: some View {
        HStack(spacing: -14) {
            ForEach(
                ["Padmé Amidala", "Luke Skywalker", "Leia Organa", "Din Djarin", "Ahsoka Tano"],
                id: \.self
            ) { name in
                Avatar(name: name, size: 64)
                    .overlay(Circle().stroke(RegardsDS.background, lineWidth: 3))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var pitch: some View {
        VStack(spacing: 12) {
            Text("Next, we'll read your contacts.")
                .font(RegardsFont.serifItalic(.title))
                .foregroundStyle(RegardsDS.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(
                "Names, phone numbers, email addresses, and the Contacts identifier used "
                + "to resume imports without duplicates. Nothing else is copied into "
                + "Regards. It stays on this phone and is never sent anywhere."
            )
            .font(.subheadline)
            .foregroundStyle(RegardsDS.muted)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .padding(.horizontal, 28)
        }
    }

    private var permissionBullets: some View {
        VStack(spacing: 0) {
            bullet(title: "Read contacts",
                   body: "Used for the first import. Regards does not write to Contacts.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RegardsDS.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(RegardsDS.hair, lineWidth: 0.5)
        )
    }

    private func bullet(title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(RegardsDS.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RegardsDS.ink)
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(RegardsDS.muted)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var allowButton: some View {
        Button(action: onAllow) {
            Text(isBusy ? "Importing contacts…" : "Allow contacts access")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                // `accentInk` so the white headline passes AA body contrast.
                .background(RegardsDS.accentInk, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityFocused($focusedRecoveryAction, equals: .allowContacts)
        .accessibilityHint(
            isBusy
                ? "Importing the contacts you selected."
                : "Opens the system Contacts permission prompt."
        )
        .accessibilityIdentifier("onboarding.allow-contacts")
    }
}
