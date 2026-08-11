import Foundation
import GRDB

/// See `GRDBContactRepository.observeTracked()`'s doc comment for why this
/// exists instead of a file-wide `@preconcurrency import GRDB`, and for why
/// `set`/`cancel` can each be called before the other. Split into its own
/// file to keep `Repositories.swift` under the lint length limit.
///
/// `NSLock`-guarded, not "safety through cardinality" alone: `set(_:)` runs
/// synchronously inside the `AsyncStream` builder closure, and `cancel()` can
/// run on whatever thread `AsyncStream.onTermination` fires on — including,
/// in the synchronous-`onError` case this exists to handle, the same call
/// stack as `set(_:)` itself, but not guaranteed to stay that way for every
/// termination path. Two unsynchronized writes to `cancellable`/`terminated`
/// from different threads would be a real data race; the lock costs nothing
/// on the cold, once-per-subscription path this runs on.
final class CancellableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellable: AnyDatabaseCancellable?
    private var terminated = false

    /// Called once, after `observation.start(...)` returns. If termination
    /// already landed first, cancels immediately instead of stashing a
    /// cancellable nothing will ever reach again.
    func set(_ cancellable: AnyDatabaseCancellable) {
        lock.lock()
        let alreadyTerminated = terminated
        if !alreadyTerminated { self.cancellable = cancellable }
        lock.unlock()
        if alreadyTerminated { cancellable.cancel() }
    }

    /// Called from `AsyncStream.onTermination`, at most once. Cancels
    /// immediately if `set(_:)` already ran; otherwise just records that
    /// termination happened, so a `set(_:)` that hasn't run yet cancels on
    /// arrival instead of leaking.
    func cancel() {
        lock.lock()
        terminated = true
        let toCancel = cancellable
        cancellable = nil
        lock.unlock()
        toCancel?.cancel()
    }
}
