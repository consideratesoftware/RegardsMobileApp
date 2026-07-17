import SwiftUI

/// Pre-permission-prompt onboarding (screen-misc.jsx::OnboardingScreen). In
/// Phase 0 the "Allow contacts access" button is a no-op placeholder; Phase 1
/// wires the real `CNContactStore.requestAccess` flow.
public struct OnboardingScreen: View {
    let onAllow: () -> Void
    let onWhyWeAsk: () -> Void

    public init(onAllow: @escaping () -> Void = {},
                onWhyWeAsk: @escaping () -> Void = {}) {
        self.onAllow = onAllow
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

                    allowButton
                        .padding(.top, 20)
                        .padding(.horizontal, 24)

                    Button("Why we ask · read the proofs", action: onWhyWeAsk)
                        .font(.subheadline.weight(.medium))
                        // Sibling to the "Allow contacts access" CTA above —
                        // body-sized tappable text, so `accentInk` for AA
                        // against the light background.
                        .foregroundStyle(RegardsDS.accentInk)
                        .padding(.top, 14)

                    Color.clear.frame(height: 40)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .accessibilityIdentifier("screen.onboarding")
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
                "Name, photo, phone, email, address, birthday, anniversary. "
                + "Nothing else. It stays on this phone — never sent anywhere, ever."
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
                   body: "Needed. Without it, Regards has nothing to remind you about.")
            Hair(inset: 17)
            bullet(title: "Write contacts",
                   body: "Optional. Only when you edit someone from inside the app.")
            Hair(inset: 17)
            bullet(title: "Read calendar",
                   body: "Optional. Catches birthdays stored in your calendar.")
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
            Text("Allow contacts access")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                // `accentInk` so the white headline passes AA body contrast.
                .background(RegardsDS.accentInk, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the system Contacts permission prompt.")
    }
}
