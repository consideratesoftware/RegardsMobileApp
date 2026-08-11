import Foundation

/// A mutable clock for tests that need real elapsed time between two calls —
/// e.g. `ContactsReconciler.archiveDebounceFloor` requires two `.authorized`
/// passes to be genuinely separated in time, which a fixed `{ someDate }`
/// closure (returning the exact same instant on every call) can never
/// satisfy. `@unchecked Sendable` + `NSLock`: the closure this hands to
/// `clock:` parameters can be called from any isolation context.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        self.current = start
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}
