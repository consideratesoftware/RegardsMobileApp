import Foundation

/// Polls `condition` up to 100 times, yielding between attempts, instead of
/// sleeping a fixed duration. Used across the suite wherever a test needs to
/// wait for an async effect (an announcement, a focus assignment, a
/// reconciliation pass) without pinning a wall-clock delay to CI speed.
@MainActor
func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// Bounded, run-loop-pumping wait for state SwiftUI's own appearance/layout
/// machinery drives — a `UIHostingController`'s `.onAppear`/`.onDisappear`
/// (fired by real `UIViewController` appearance-transition bookkeeping) and
/// `TabView` selection changes both need the actual `RunLoop` spinning to
/// commit, not just the cooperative-pool yield `eventually` gives. Round 9
/// (`RootViewSceneActivationTests`) found this for `.task`-driven state on
/// `RootView`; round 11 (`AllContactsCorruptionAnnouncementTests`) found the
/// same gap for `.onAppear`/`.onDisappear`-driven state on `AllContactsScreen`
/// hosted inside a `TabView` — a plain `eventually` around a tab-switch
/// negative assertion passed even when the disappear transition hadn't
/// landed yet, because `Task.yield()` alone never gives UIKit's real
/// appearance-transition machinery a chance to run. Ceiling of
/// `maxIterations * 0.05s` (15s by default) so a genuinely-broken binding
/// fails the test instead of hanging it.
@MainActor
func eventuallyPumpingRunLoop(
    maxIterations: Int = 300,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<maxIterations {
        if condition() { return true }
        await Task.yield()
        pumpRunLoopBriefly()
    }
    return condition()
}

/// `RunLoop.current` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — it can only be
/// read from a synchronous context, hence this non-`async` wrapper instead
/// of calling it directly inside `eventuallyPumpingRunLoop`'s loop.
@MainActor
func pumpRunLoopBriefly() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

/// Settles a single `@Published`/`@State` assignment before a test moves on
/// to the next one, when a single `pumpRunLoopBriefly()` call isn't reliably
/// enough for SwiftUI's environment/Combine-driven update to actually commit
/// (round 9: a three-assignment-in-a-row scene-phase sequence needed several
/// rounds, not one). Several yield-and-pump rounds gives that update more
/// chances to land before the next assignment overwrites it.
@MainActor
func settleViewUpdate(iterations: Int = 5) async {
    for _ in 0..<iterations {
        await Task.yield()
        pumpRunLoopBriefly()
    }
}
