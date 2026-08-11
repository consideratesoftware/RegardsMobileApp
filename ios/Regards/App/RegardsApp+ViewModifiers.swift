import SwiftUI

// Split from RegardsApp.swift (lint file-length limit): small,
// self-contained `ViewModifier`s with no dependency on `RootView` or
// `RegardsTabRoot`.

/// Gives UI tests a deterministic way to exercise accessibility layouts
/// without changing the shared Simulator's system settings.
struct UITestDynamicTypeOverride: ViewModifier {
#if DEBUG
    private let requestedSize = ProcessInfo.processInfo.environment["REGARDS_UI_TEST_DYNAMIC_TYPE"]
#endif

    @ViewBuilder
    func body(content: Content) -> some View {
#if DEBUG
        if requestedSize == "accessibility5" {
            content.environment(\.dynamicTypeSize, .accessibility5)
        } else {
            content
        }
#else
        content
#endif
    }
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
