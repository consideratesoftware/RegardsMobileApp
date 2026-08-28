import SwiftUI

/// Initials placeholder avatar. Mirrors the JSX `<Avatar>`:
///   - Two-letter initials from name words.
///   - Deterministic tone picked from a 5-palette by summed-char-code hash.
///   - Optional accent ring for inner-circle contacts.
///
/// The mock explicitly says "initials placeholders until real photos load"
/// (regards-ui.jsx top comment) — real `CNContact` photo loading is a Phase 1
/// responsibility.
public struct Avatar: View {
    public let name: String
    public let size: CGFloat
    public let hasAccentRing: Bool
    /// Whether to draw the two-letter monogram inside the circle.
    ///
    /// `false` for the list rows whose accessibility subtree is substituted
    /// wholesale by `.accessibilityRepresentation` (Overdue, Upcoming). The
    /// monogram is decorative — it is derived from the name the row already
    /// announces — but it is still *text on screen*, and once the row's real
    /// subtree is replaced there is no accessibility element behind those
    /// pixels for Apple's audit to find. That is a genuine
    /// "Potentially inaccessible text" finding, not a false positive, and
    /// bisecting confirmed the monogram is the sole cause: removing it takes
    /// the Overdue audit from one issue to zero. Avatar-level fixes do not
    /// work, because the substitution happens above them — both making the
    /// avatar a represented element and rasterising it with `.drawingGroup()`
    /// leave the finding in place (both tried).
    ///
    /// Larger avatars keep their monogram: Contact Detail, Edit Contact,
    /// Onboarding, Merge and All Contacts do not substitute their
    /// accessibility subtrees, so their monograms sit inside a real element
    /// and the audit is satisfied.
    public let showsInitials: Bool

    public init(
        name: String,
        size: CGFloat = 44,
        hasAccentRing: Bool = false,
        showsInitials: Bool = true
    ) {
        self.name = name
        self.size = size
        self.hasAccentRing = hasAccentRing
        self.showsInitials = showsInitials
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(tone.background)
                .frame(width: size, height: size)
            // Initials size is intentionally fixed — the audit's
            // dynamic-type check flags this, but scaling the text inside
            // a fixed-diameter circle clips at accessibility tiers
            // regardless of `minimumScaleFactor`. Avatar is
            // `.accessibilityHidden(true)`; parent rows own the VoiceOver
            // label, and the visible letters are purely decorative. Noted
            // as a known trade-off in `ios/docs/accessibility.md`.
            if showsInitials {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(tone.foreground)
                    .kerning(0.2)
            }
        }
        // `.overlay` doesn't participate in parent layout — the ring draws
        // outside the avatar's bounding frame without changing the hit box
        // or nudging neighbors by 6pt whenever `hasAccentRing` flips.
        .overlay {
            if hasAccentRing {
                Circle()
                    .stroke(RegardsDS.accent, lineWidth: 1.5)
                    .frame(width: size + 6, height: size + 6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Private

    private var initials: String {
        let letters = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
        return letters.isEmpty ? "·" : letters
    }

    private var tone: AvatarTone {
        let hash = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return AvatarTone.palette[hash % AvatarTone.palette.count]
    }
}

/// Fixed 5-tone palette. Every color is constructed via `Color(.sRGB, ...)`
/// so wide-gamut displays match the rest of the design system (`RegardsPalette`
/// is explicit sRGB). The unqualified `Color(red:green:blue:)` convenience
/// initializer uses the generic RGB space, which drifts from sRGB off P3.
struct AvatarTone: Sendable {
    let background: Color
    let foreground: Color

    static let palette: [AvatarTone] = [
        AvatarTone(background: Color(.sRGB, red: 0.89, green: 0.87, blue: 0.81, opacity: 1),
                   foreground: Color(.sRGB, red: 0.38, green: 0.34, blue: 0.27, opacity: 1)),
        AvatarTone(background: Color(.sRGB, red: 0.85, green: 0.91, blue: 0.84, opacity: 1),
                   foreground: Color(.sRGB, red: 0.22, green: 0.38, blue: 0.27, opacity: 1)),
        AvatarTone(background: Color(.sRGB, red: 0.83, green: 0.89, blue: 0.94, opacity: 1),
                   foreground: Color(.sRGB, red: 0.22, green: 0.32, blue: 0.47, opacity: 1)),
        AvatarTone(background: Color(.sRGB, red: 0.92, green: 0.86, blue: 0.84, opacity: 1),
                   foreground: Color(.sRGB, red: 0.44, green: 0.25, blue: 0.22, opacity: 1)),
        AvatarTone(background: Color(.sRGB, red: 0.90, green: 0.85, blue: 0.92, opacity: 1),
                   foreground: Color(.sRGB, red: 0.37, green: 0.22, blue: 0.42, opacity: 1)),
    ]
}
