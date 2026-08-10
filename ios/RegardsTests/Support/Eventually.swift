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
