import SwiftUI

/// Announces a row-removing list action (Caught up / Snooze) and lands
/// accessibility focus on a stable target once the list has settled.
///
/// Mirrors `LaunchFailureAccessibilityEffects` (`RegardsApp.swift`) and
/// `OnboardingAccessibilityEffects`'s announce → yield → focus sequence:
/// removing a focused row with no announcement and nowhere for focus to land
/// silently drops the VoiceOver cursor. `yieldControl` gives SwiftUI's
/// accessibility tree a beat to catch up with the just-applied optimistic
/// removal before the announcement and focus move fire against it.
struct RowActionAccessibilityEffects {
    let announce: @MainActor (String) -> Void
    let didFocus: @MainActor () -> Void
    let yieldControl: @MainActor () async -> Void

    init(
        announce: @escaping @MainActor (String) -> Void,
        didFocus: @escaping @MainActor () -> Void = {},
        yieldControl: @escaping @MainActor () async -> Void = { await Task.yield() }
    ) {
        self.announce = announce
        self.didFocus = didFocus
        self.yieldControl = yieldControl
    }

    static let live = RowActionAccessibilityEffects(
        announce: { AccessibilityNotification.Announcement($0).post() }
    )
}
