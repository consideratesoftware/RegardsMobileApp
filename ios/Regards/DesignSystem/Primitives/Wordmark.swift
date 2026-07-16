import SwiftUI

/// The "regards" lowercase-italic wordmark. Used in the nav bar, the splash,
/// and the widget scene. Intentionally fixed-size — the wordmark is a brand
/// mark, not copy. Each caller picks the rendered size for the context
/// (`size: 17` in nav bars, `size: 48` in Onboarding, `@ScaledMetric`-wrapped
/// in `SplashView`). Noted as a known dynamic-type finding in
/// `ios/docs/accessibility.md`.
public struct Wordmark: View {
    public let size: CGFloat
    public let color: Color?

    public init(size: CGFloat = 24, color: Color? = nil) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Text("regards")
            .font(.system(size: size, design: .serif).italic())
            .foregroundStyle(color ?? RegardsDS.ink)
            .kerning(-0.5)
            .accessibilityLabel("Regards")
    }
}

/// 0.5pt hairline divider. `inset` pads the leading edge so it can align with
/// avatar-aware row content.
public struct Hair: View {
    public let inset: CGFloat

    public init(inset: CGFloat = 0) {
        self.inset = inset
    }

    public var body: some View {
        RegardsDS.hair
            .frame(height: 0.5)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// Uppercase muted caption used as the label above every content card.
public struct SectionHeader: View {
    public let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title.uppercased())
            .font(RegardsFont.sectionHeader())
            .foregroundStyle(RegardsDS.muted)
            .kerning(0.8)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            // The visual `.uppercased()` is decorative typography. VoiceOver
            // should hear the natural casing — abbreviations like "WED" or
            // "MON" in the uppercased output get parsed as letter-by-letter
            // acronyms or trip the audit's "Label not human-readable"
            // check. Setting an explicit accessibilityLabel decouples
            // presentation from spoken output.
            .accessibilityLabel(title)
    }
}

/// Rounded white card container used to group list rows. Matches the 20pt
/// corner-radius surface from the JSX `<Card>`.
public struct RegardsCard<Content: View>: View {
    private let inset: CGFloat
    private let content: Content

    public init(inset: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.inset = inset
        self.content = content()
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RegardsDS.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(RegardsDS.hair, lineWidth: 0.5)
            )
            .padding(.horizontal, inset)
    }
}
