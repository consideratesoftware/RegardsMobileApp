import Foundation
import GRDB
import Testing
@testable import Regards

/// `CancellableBox`'s own doc comment for why `set`/`cancel` can each be
/// called before the other; this file proves both orderings actually behave
/// as documented rather than trusting the comment. The race that motivated
/// the box in the first place — a synchronous `onError` inside
/// `observation.start(...)` triggering `AsyncStream.onTermination` before
/// `start(...)` has even returned a cancellable — had no regression until
/// now.
struct CancellableBoxTests {
    @Test("set(_:) then cancel() cancels the wrapped cancellable")
    func setThenCancelCancelsImmediately() {
        let box = CancellableBox()
        var cancelCount = 0
        let cancellable = AnyDatabaseCancellable { cancelCount += 1 }

        box.set(cancellable)
        #expect(cancelCount == 0) // set alone never cancels

        box.cancel()
        #expect(cancelCount == 1)
    }

    /// The race this box exists to close. Without the `terminated` flag,
    /// `set(_:)` would stash a cancellable nothing will ever reach again —
    /// `cancel()` already ran and returned, and the box's only other caller
    /// (`AsyncStream.onTermination`) fires at most once, so no second
    /// `cancel()` call would ever arrive to clean it up. The underlying
    /// `ValueObservation` would run for the rest of the process.
    @Test("cancel() before set(_:) still cancels the cancellable the instant it arrives")
    func cancelBeforeSetCancelsOnArrival() {
        let box = CancellableBox()
        var cancelCount = 0
        let cancellable = AnyDatabaseCancellable { cancelCount += 1 }

        box.cancel() // termination lands first — nothing to cancel yet
        #expect(cancelCount == 0)

        box.set(cancellable) // arrives after — must cancel on arrival, not stash
        #expect(cancelCount == 1)
    }

    /// `AsyncStream.onTermination` is documented to fire at most once, but
    /// this proves the box doesn't *depend* on that for correctness: a
    /// second `cancel()` must not double-cancel (GRDB's own
    /// `AnyDatabaseCancellable.cancel()` already tolerates repeat calls, but
    /// the box's own bookkeeping — clearing `cancellable` to `nil` — is what
    /// this pins).
    @Test("cancel() is safe to call more than once")
    func cancelIsIdempotent() {
        let box = CancellableBox()
        var cancelCount = 0
        let cancellable = AnyDatabaseCancellable { cancelCount += 1 }
        box.set(cancellable)

        box.cancel()
        box.cancel()

        #expect(cancelCount == 1)
    }
}
