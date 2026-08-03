import SwiftUI

/// Chooses a compact or accessibility-sized layout while keeping the
/// responsive policy in one shared place.
public struct AccessibilityAdaptiveLayout<RegularContent: View, AccessibilityContent: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let regularContent: RegularContent
    private let accessibilityContent: AccessibilityContent

    public init(
        @ViewBuilder regular: () -> RegularContent,
        @ViewBuilder accessibility: () -> AccessibilityContent
    ) {
        self.regularContent = regular()
        self.accessibilityContent = accessibility()
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityContent
            } else {
                regularContent
            }
        }
    }
}
