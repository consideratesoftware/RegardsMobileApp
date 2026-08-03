import Foundation

/// sRGB components (0-1) for every color the design system exposes. The asset
/// catalog (Assets.xcassets) holds the rendered values; this struct is the
/// Swift-level source of truth for the **contrast tests** that run in CI —
/// they compute WCAG ratios from these tuples without having to crack open
/// the xcassets JSON.
///
/// Keep this file in sync with `ios/Regards/Resources/Assets.xcassets/*` —
/// PR2's `ColorContrastTests` asserts the pairs listed in
/// `ios/docs/accessibility.md`.
public enum RegardsPalette {

    public struct SRGB: Sendable, Equatable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(_ red: Double, _ green: Double, _ blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }

        public var tuple: (red: Double, green: Double, blue: Double) {
            (red, green, blue)
        }
    }

    // MARK: - Light mode

    public static let backgroundLight  = SRGB(0.984, 0.973, 0.945)   // warm off-white
    public static let surfaceLight     = SRGB(1.000, 1.000, 1.000)
    public static let inkLight         = SRGB(0.165, 0.149, 0.133)   // near-black warm
    public static let mutedLight       = SRGB(0.420, 0.390, 0.360)   // darkened post-PR1-audit
    public static let faintLight       = SRGB(0.700, 0.680, 0.660)
    public static let hairLight        = SRGB(0.855, 0.845, 0.825)
    public static let hairSoftLight    = SRGB(0.915, 0.905, 0.885)
    public static let accentLight      = SRGB(0.784, 0.419, 0.247)   // terracotta
    public static let accentSoftLight  = SRGB(0.967, 0.913, 0.879)
    public static let accentInkLight   = SRGB(0.490, 0.235, 0.145)
    public static let dangerLight      = SRGB(0.720, 0.300, 0.220)

    // MARK: - Dark mode

    public static let backgroundDark   = SRGB(0.082, 0.075, 0.059)
    public static let surfaceDark      = SRGB(0.125, 0.114, 0.094)
    public static let inkDark          = SRGB(0.957, 0.945, 0.918)
    public static let mutedDark        = SRGB(0.650, 0.632, 0.600)   // lifted to pass AA vs backgroundDark
    public static let faintDark        = SRGB(0.420, 0.408, 0.390)
    public static let hairDark         = SRGB(0.200, 0.190, 0.170)
    public static let hairSoftDark     = SRGB(0.155, 0.145, 0.128)
    public static let accentDark       = SRGB(0.843, 0.490, 0.318)
    public static let accentSoftDark   = SRGB(0.235, 0.145, 0.098)
    public static let accentInkDark    = SRGB(0.920, 0.625, 0.465)
    public static let dangerDark       = SRGB(0.870, 0.430, 0.330)

    // MARK: - Commonly-paired combinations

    /// Contrast-pair registry — every fg/bg combo actually rendered in the
    /// app, with its required WCAG minimum. `ColorContrastTests` asserts each
    /// meets or exceeds its minimum.
    public struct Pair: Sendable, CustomStringConvertible {
        public let name: String
        public let foreground: SRGB
        public let background: SRGB
        public let minimumRatio: Double    // WCAG AA: 4.5 body, 3.0 large/icon

        public var description: String { name }
    }

    public static let contrastPairs: [Pair] = [
        .init(name: "Ink on Background (light)",
              foreground: inkLight, background: backgroundLight, minimumRatio: 4.5),
        .init(name: "Ink on Background (dark)",
              foreground: inkDark,  background: backgroundDark,  minimumRatio: 4.5),
        .init(name: "Muted on Background (light)",
              foreground: mutedLight, background: backgroundLight, minimumRatio: 4.5),
        .init(name: "Muted on Background (dark)",
              foreground: mutedDark, background: backgroundDark,   minimumRatio: 4.5),
        .init(name: "Muted on Hair Soft (light)",
              foreground: mutedLight, background: hairSoftLight, minimumRatio: 4.5),
        .init(name: "Muted on Hair Soft (dark)",
              foreground: mutedDark, background: hairSoftDark, minimumRatio: 4.5),
        .init(name: "Accent Ink on Accent Soft (light)",
              foreground: accentInkLight, background: accentSoftLight, minimumRatio: 4.5),
        .init(name: "Accent Ink on Accent Soft (dark)",
              foreground: accentInkDark, background: accentSoftDark, minimumRatio: 4.5),
        .init(name: "White on Accent (light)",
              foreground: SRGB(1, 1, 1), background: accentLight,  minimumRatio: 3.0),
        .init(name: "White on Accent (dark)",
              foreground: SRGB(1, 1, 1), background: accentDark,   minimumRatio: 3.0),
    ]
}
