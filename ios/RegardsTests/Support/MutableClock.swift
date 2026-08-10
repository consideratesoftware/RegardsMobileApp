import Foundation

/// A clock a test can advance between calls, for asserting "X happens after
/// N days" without depending on wall-clock time. `@unchecked Sendable` is
/// justified here (not on any production type): `current` is only ever
/// mutated and read from the single `@MainActor` test that owns the
/// instance, but `SchedulingPass.init` requires `@Sendable () -> Date` since
/// it's an actor — the lock makes that requirement genuinely safe rather
/// than merely quiet.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
