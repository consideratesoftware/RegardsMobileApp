import Foundation
import Testing
import UIKit
@testable import Regards

/// WCAG contrast gate for the design-system palette. Runs on every PR — if a
/// color tweak drops a pair below its minimum ratio, CI fails before the
/// pixels ever reach a screen.
struct ColorContrastTests {

    @Test("Every registered contrast pair meets or exceeds its minimum ratio",
          arguments: RegardsPalette.contrastPairs)
    func pairMeetsMinimum(pair: RegardsPalette.Pair) {
        let ratio = WCAGContrast.ratio(
            foreground: pair.foreground.tuple,
            background: pair.background.tuple)
        #expect(ratio >= pair.minimumRatio,
                "\(pair.name): ratio \(String(format: "%.2f", ratio)) < required \(pair.minimumRatio)")
    }

    @Test("WCAG ratio formula produces known reference values")
    func knownRatios() {
        // White-on-black is the canonical 21:1.
        let white = (red: 1.0, green: 1.0, blue: 1.0)
        let black = (red: 0.0, green: 0.0, blue: 0.0)
        #expect(abs(WCAGContrast.ratio(foreground: white, background: black) - 21.0) < 0.01)
        // Same color on itself is exactly 1:1.
        #expect(abs(WCAGContrast.ratio(foreground: white, background: white) - 1.0) < 0.0001)
    }

    /// The generic test above passes for whatever the registry holds, so
    /// removing a pair, lowering its minimum, or pointing it at other colors
    /// would go unnoticed. These are rendered pairs that were once checked only
    /// by dedicated tests or not at all: the Settings notification error line,
    /// the Cadence card's Status row, and muted and accent-ink text on cards.
    /// All are body text.
    @Test("The registry keeps the Danger, Muted and Accent Ink pairs on Background and Surface at 4.5")
    func registryKeepsDangerMutedAndAccentInkSurfacePairs() {
        typealias Colors = (foreground: RegardsPalette.SRGB, background: RegardsPalette.SRGB)
        let required: [String: Colors] = [
            "Danger on Background (light)": (RegardsPalette.dangerLight, RegardsPalette.backgroundLight),
            "Danger on Background (dark)": (RegardsPalette.dangerDark, RegardsPalette.backgroundDark),
            "Danger on Surface (light)": (RegardsPalette.dangerLight, RegardsPalette.surfaceLight),
            "Danger on Surface (dark)": (RegardsPalette.dangerDark, RegardsPalette.surfaceDark),
            "Muted on Surface (light)": (RegardsPalette.mutedLight, RegardsPalette.surfaceLight),
            "Muted on Surface (dark)": (RegardsPalette.mutedDark, RegardsPalette.surfaceDark),
            "Accent Ink on Surface (light)": (RegardsPalette.accentInkLight, RegardsPalette.surfaceLight),
            "Accent Ink on Surface (dark)": (RegardsPalette.accentInkDark, RegardsPalette.surfaceDark),
        ]

        for (name, colors) in required {
            let matches = RegardsPalette.contrastPairs.filter { $0.name == name }
            #expect(matches.count == 1, "contrastPairs should list \(name) once, found \(matches.count)")
            guard let pair = matches.first else { continue }
            #expect(pair.minimumRatio == 4.5, "\(name) is body text and needs 4.5")
            #expect(pair.foreground == colors.foreground, "\(name) has the wrong foreground")
            #expect(pair.background == colors.background, "\(name) has the wrong background")
        }
    }

    @Test("Muted light vs Background light is comfortably above AA body threshold")
    func mutedLightAboveAA() {
        let ratio = WCAGContrast.ratio(
            foreground: RegardsPalette.mutedLight.tuple,
            background: RegardsPalette.backgroundLight.tuple)
        // The PR1 audit caught the original value at ~3.9:1; we should now be
        // well above 4.5.
        #expect(ratio >= 4.5, "muted-on-bg = \(ratio)")
    }
}

struct AssetCatalogHygieneTests {

    @Test("Obsolete palette assets are absent while system-owned colors remain")
    func obsoletePaletteColorsAreAbsent() {
        #expect(UIColor(named: "Ink") == nil)
        #expect(UIColor(named: "Muted") == nil)
        #expect(UIColor(named: "Background") == nil)
        #expect(UIColor(named: "AccentColor") != nil)
        #expect(UIColor(named: "LaunchBackground") != nil)
    }
}
