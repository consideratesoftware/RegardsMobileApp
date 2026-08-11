import Foundation

/// Owns an `observeTracked()` subscription `Task` on behalf of an
/// `@MainActor` view model, so the subscription ends deterministically when
/// the view model deallocates rather than only on the stream's *next*
/// emission (staged review round 10 coverage gap).
///
/// Exists specifically to work around a Swift-language wall, not as a
/// design preference: `OverdueViewModel`/`UpcomingViewModel`'s
/// `[weak self]`-guarded loop inside their subscription `Task` only
/// notices the view model is gone when `observeTracked()`'s stream next
/// emits, which may never happen once nothing else references the view
/// model — leaving that Task, and its registration with the underlying
/// repository, alive indefinitely. A `deinit { observationTask?.cancel() }`
/// directly on the `@MainActor` view model can't do this: `deinit` is
/// itself nonisolated even for a global-actor-isolated class in this
/// language mode, and `nonisolated` cannot be applied to a mutable stored
/// property to bridge that gap ("nonisolated cannot be applied to mutable
/// stored properties"). Delegating ownership to this ordinary, ARC-managed
/// reference type sidesteps the restriction entirely: its own `deinit` is
/// already nonisolated by construction, and it fires the instant the last
/// strong reference — the owning view model's `let` property below — goes
/// away, which happens exactly when the view model itself deallocates.
///
/// `@unchecked Sendable`, and `task` is a plain, unsynchronized `var`: only
/// one strong reference to a given token ever exists — held by the owning
/// `@MainActor` view model's own `let` property — so every read/write of
/// `task` from that view model's methods is already serialized by the
/// MainActor, and `deinit` (the only other access) by definition runs
/// after that last strong reference is gone, when nothing concurrent
/// remains to race against.
final class ObservationSubscriptionToken: @unchecked Sendable {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }
}
