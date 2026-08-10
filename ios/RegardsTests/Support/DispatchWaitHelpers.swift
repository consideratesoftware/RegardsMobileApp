import Foundation

/// `DispatchSemaphore.wait(timeout:)` is unavailable directly from an
/// `async` function body (Swift 6 flags it as a context that shouldn't
/// block a cooperative-pool thread), so the call is boxed in a plain
/// synchronous helper — legal from any context, async or not. Shared by
/// `ContactsSourceTests` and `ContactsSourceStressTests`, both of which use
/// `DispatchSemaphore`-based signaling to prove `runOffCooperativePool`
/// keeps the cooperative pool responsive without a wall-clock assertion.
func waitWithBoundedTimeout(
    _ semaphore: DispatchSemaphore,
    seconds: Double = 5
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + seconds)
}
