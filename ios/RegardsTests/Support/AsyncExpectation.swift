import Foundation

/// Waits for `condition` to become true by cooperatively yielding the
/// current task, never by sleeping — no wall-clock dependency, so this never
/// races real elapsed time and never pads a passing run with a fixed delay.
///
/// Used where a repository write's effect reaches a `@MainActor` view model
/// through a separately scheduled `Task` (`observeTracked()`'s subscriber
/// loop) rather than through a call the test itself awaits. `maxYields` is a
/// safety valve against a genuinely broken condition hanging the suite, not
/// a timing budget: a passing check normally resolves within a handful of
/// yields, since the consuming `Task` only needs a few scheduler turns to
/// drain a value already sitting in its stream's buffer.
///
/// `@MainActor`: every call site closes over a `@MainActor` view model's
/// state, so this runs on the same actor rather than asking the compiler to
/// prove a plain closure capturing that state is safe to hand across an
/// isolation boundary.
///
/// Shared, not a copy-per-file convenience: call sites across several
/// feature and support test files, all waiting on the same shape of problem
/// — a repository broadcast landing on a subscriber `Task` this test doesn't
/// otherwise await, or any other condition that resolves off the calling
/// `Task`. One implementation keeps the "never sleep, never guess a timeout"
/// rule enforced in one place instead of re-derived per call site
/// (`RowActionAccessibilityEffectsTests` used to keep its own copy, named
/// `eventually`, before consolidating onto this one).
@MainActor
@discardableResult
func waitUntil(maxYields: Int = 10_000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<maxYields {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
