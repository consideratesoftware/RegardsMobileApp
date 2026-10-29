import SwiftUI

/// The first onboarding screen (ARCHITECTURE.md §10.8 (a)): what Regards is
/// for, before any permission ask. Its one action moves to the Contacts
/// pre-prompt (`OnboardingScreen`).
struct OnboardingConceptScreen: View {
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 10) {
                        Wordmark(size: 48)
                        Text("Keep your people in your regards".uppercased())
                            .font(.caption2.weight(.medium))
                            .kerning(1.5)
                            .foregroundStyle(RegardsDS.muted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, proxy.safeAreaInsets.top + 24)

                    VStack(spacing: 12) {
                        Text("Who have you been meaning to call?")
                            .font(RegardsFont.serifItalic(.title))
                            .foregroundStyle(RegardsDS.ink)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(
                            "Pick a few people and how often you want to be in touch. "
                            + "Regards reminds you when it's been too long, at times that suit you."
                        )
                        .font(.subheadline)
                        .foregroundStyle(RegardsDS.muted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        Text("Everything stays on this phone.")
                            .font(.subheadline)
                            .foregroundStyle(RegardsDS.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 48)

                    Button(action: onContinue) {
                        Text("Get started")
                            .font(.headline)
                            .foregroundStyle(RegardsDS.background)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 54)
                            .padding(.vertical, 8)
                            .background(RegardsDS.accentInk, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboarding.get-started")
                    .padding(.top, 32)
                    .padding(.horizontal, 24)

                    Color.clear.frame(height: 40)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .accessibilityIdentifier("screen.onboarding-concept")
    }
}
