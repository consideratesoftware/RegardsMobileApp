import SwiftUI

// Split from RegardsApp.swift (lint file-length limit): small,
// self-contained `ViewModifier`s with no dependency on `RootView` or
// `RegardsTabRoot`.

/// Gives UI tests a deterministic way to exercise accessibility layouts
/// without changing the shared Simulator's system settings.
///
/// Widened from a single hardcoded "accessibility5" check to the full
/// `DynamicTypeSize` range (staged review round 11): the render-matrix work
/// that found the Overdue row-crowding bug needed the *smallest* size, not
/// just the largest, and `simctl ui <udid> content_size <value>` — the
/// mechanism used to gather that evidence by hand — mutates the whole
/// Simulator's system setting, which is exactly what this override exists
/// to avoid needing for a self-contained, parallelizable regression test.
/// `launchToOverdue(dynamicTypeSize:)` already accepted an arbitrary string
/// before this change; only the app side ever recognized just one value.
struct UITestDynamicTypeOverride: ViewModifier {
#if DEBUG
    private let requestedSize = ProcessInfo.processInfo.environment["REGARDS_UI_TEST_DYNAMIC_TYPE"]
        .flatMap(Self.dynamicTypeSize(named:))
#endif

    @ViewBuilder
    func body(content: Content) -> some View {
#if DEBUG
        if let requestedSize {
            content.environment(\.dynamicTypeSize, requestedSize)
        } else {
            content
        }
#else
        content
#endif
    }

#if DEBUG
    // `nonisolated`: used as a bare function value inside the stored
    // property initializer above, which runs outside `body`'s implicit
    // `@MainActor` isolation — a pure string-to-enum mapping needs none of
    // that isolation anyway.
    nonisolated static func dynamicTypeSize(named name: String) -> DynamicTypeSize? {
        switch name {
        case "xSmall": return .xSmall
        case "small": return .small
        case "medium": return .medium
        case "large": return .large
        case "xLarge": return .xLarge
        case "xxLarge": return .xxLarge
        case "xxxLarge": return .xxxLarge
        case "accessibility1": return .accessibility1
        case "accessibility2": return .accessibility2
        case "accessibility3": return .accessibility3
        case "accessibility4": return .accessibility4
        case "accessibility5": return .accessibility5
        default: return nil
        }
    }
#endif
}

struct RegardsTabBarBehavior: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
