import SwiftUI
import UIKit

/// Announces a row-removing list action (Caught up / Snooze) and lands
/// accessibility focus on a stable target once the list has settled.
///
/// Mirrors `LaunchFailureAccessibilityEffects` (`RegardsApp.swift`) and
/// `OnboardingAccessibilityEffects`'s announce → yield → focus sequence:
/// removing a focused row with no announcement and nowhere for focus to land
/// silently drops the VoiceOver cursor. `yieldControl` gives SwiftUI's
/// accessibility tree a beat to catch up with the just-applied optimistic
/// removal before the announcement and focus move fire against it.
///
/// `public`: referenced in `OverdueScreen`/`UpcomingScreen`'s `public init`
/// parameter lists (no default — see those types for why).
public struct RowActionAccessibilityEffects {
    let announce: @MainActor (String) -> Void
    let didFocus: @MainActor () -> Void
    let yieldControl: @MainActor () async -> Void

    public init(
        announce: @escaping @MainActor (String) -> Void,
        didFocus: @escaping @MainActor () -> Void = {},
        yieldControl: @escaping @MainActor () async -> Void = { await Self.settleRunLoop() }
    ) {
        self.announce = announce
        self.didFocus = didFocus
        self.yieldControl = yieldControl
    }

    /// `Task.yield()` only yields to Swift's cooperative thread-pool
    /// scheduler — it says nothing about whether UIKit's run loop has
    /// actually turned, committed a pending `CATransaction`, or handed the
    /// just-applied SwiftUI diff to the accessibility subsystem. On device
    /// (unlike the unit-test host, which has no real run loop pressure) that
    /// gap was enough for `didFocus`'s `isSubtitleFocused = true` to land
    /// before VoiceOver's tree actually reflected the row removal, so the
    /// focus move silently missed. Scheduling through `RunLoop.current`
    /// instead waits for a real pass of the run loop this view is hosted on.
    ///
    /// `inModes: [.common]`, not the `.default`-only mode `perform(_:)`
    /// implies: `.default` mode is suspended for the duration of an
    /// in-flight scroll or other tracking loop, so a row action taken while
    /// the list is still decelerating would sit queued until scrolling
    /// stops — the announcement and focus move landing late enough to read
    /// as not having happened at all. `.common` includes both `.default`
    /// and `.tracking`, so this fires on the next run-loop turn regardless
    /// of what the list is doing.
    ///
    /// `public`: used as the `yieldControl` default argument value in the
    /// `public init` above, and default-argument expressions are evaluated
    /// at the call site, so this needs to be at least as visible as that
    /// init.
    @MainActor
    public static func settleRunLoop() async {
        await withCheckedContinuation { continuation in
            RunLoop.current.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    /// Announces at `.high` speech priority so VoiceOver interrupts whatever
    /// it's currently saying instead of queuing (or on some versions,
    /// silently dropping) the announcement behind other speech — a plain
    /// `String` announcement posts at default priority.
    ///
    /// `didFocus` is deliberately a no-op here, not a `.layoutChanged` post:
    /// an early version fired one, and it re-broke the exact bug `.high`
    /// priority was added to fix. `fire`'s sequencing (see
    /// `RowActionAnnouncer`) already calls `focus()` — which flushes
    /// VoiceOver's speech queue as a side effect of any focus change —
    /// *before* `announce`, specifically so nothing after the announcement
    /// interrupts it. A `.layoutChanged` post from `didFocus`, which runs
    /// after `announce`, would be exactly such an interruption: a second
    /// focus event flushing the announcement all over again. `didFocus`
    /// stays as an explicit hook (tests observe it), just wired to nothing
    /// live.
    @MainActor
    public static let live = RowActionAccessibilityEffects(
        announce: { message in
            var announcement = AttributedString(message)
            announcement.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(announcement).post()
        },
        didFocus: {}
    )
}

/// Sequences a row-removing action's focus → yield → announce steps behind
/// a generation counter, so a second row action fired before the first's
/// sequence resumes past its yields invalidates the first's still-pending
/// focus move and announcement. `OverdueScreen` and `UpcomingScreen` each
/// held this as a private `@State` counter plus an inline method; pulled out
/// here so it's one piece of logic instead of two duplicated copies, and so
/// `RowActionAccessibilityEffectsTests` can drive it directly.
///
/// Focus lands *before* the announcement, not after: a VoiceOver focus
/// change flushes the speech queue, and "Marked Padmé caught up" takes over
/// a second to speak — long enough that a focus move landing anywhere
/// during it cuts the announcement off mid-word. `.high` speech priority
/// (see `RowActionAccessibilityEffects.live`) doesn't save this, because
/// priority arbitrates between two announcements, not between an
/// announcement and focus-driven speech. Moving focus first and announcing
/// last, with nothing after it in the sequence to flush it, is what
/// actually fixes the device report of "I heard the row count change, not
/// the confirmation."
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
            focus()
            effects.didFocus()
            await effects.yieldControl()
            guard self.generation == current else { return }
            effects.announce(message)
        }
    }
}
