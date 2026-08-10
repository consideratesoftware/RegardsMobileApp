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

/// Sequences a row-removing action's announce → yield → focus steps behind
/// a generation counter, so a second row action fired before the first's
/// sequence resumes past its yields invalidates the first's still-pending
/// announcement and focus move. `OverdueScreen` and `UpcomingScreen` each
/// held this as a private `@State` counter plus an inline method; pulled out
/// here so it's one piece of logic instead of two duplicated copies, and so
/// `RowActionAccessibilityEffectsTests` can drive it directly.
///
/// That last point is a real constraint, not a preference: SwiftUI does not
/// publish a queryable `UIAccessibilityContainer` tree in a plain XCTest
/// unit-test host unless VoiceOver is actually running — confirmed by
/// dumping a hosted screen's full view tree via
/// `accessibilityElementCount()`/`accessibilityElement(at:)`, which returned
/// 0 throughout even after attaching a real `UIWindowScene` and calling
/// `makeKeyAndVisible()`. There is no way to reach a row button's tap
/// closure from a unit test the way `OnboardingAccessibilityEffects`'
/// reactive (model-change-driven) trigger allows a test to reach it without
/// simulating a tap at all. Injecting this type is what makes the
/// sequencing testable without one; the screens still own the button →
/// `fire(...)` wiring, verified by source and by
/// `ScreensAccessibilityTests+RowActions.swift`'s XCUITest coverage, which
/// does have full accessibility-tree access.
///
/// A `@State`-held instance (constructed via the screen's `init`, wrapped in
/// `State(initialValue:)`) rather than a plain stored property: the
/// generation counter must survive every re-render of the screen's own
/// identity, including a full reconstruction by its parent (e.g. a
/// `NavigationStack` pop back from Contact Detail) — a plain `var`
/// default-initialized on the struct would silently reset to a fresh
/// instance on any such reconstruction, quietly defeating the guard.
@MainActor
public final class RowActionAnnouncer {
    private var generation = 0

    // `public`: referenced in `OverdueScreen`/`UpcomingScreen`'s `public
    // init` parameter list (both the type and this default argument).
    public init() {}

    func fire(
        _ message: String,
        effects: RowActionAccessibilityEffects,
        focus: @escaping @MainActor () -> Void
    ) {
        generation &+= 1
        let current = generation
        Task { @MainActor [weak self] in
            await effects.yieldControl()
            guard let self, self.generation == current else { return }
            effects.announce(message)
            await effects.yieldControl()
            guard self.generation == current else { return }
            focus()
            effects.didFocus()
        }
    }
}
