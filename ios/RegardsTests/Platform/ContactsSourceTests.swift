import Foundation
import Testing
@testable import Regards

/// R25 — `CNContactsSource.fetchAllContacts` used to run `enumerateContacts`
/// synchronously on whatever cooperative-pool thread the runtime handed the
/// calling `async` function, which stalled that worker for as long as a
/// large address book took to enumerate (measured at ~5k contacts). The fix
/// is the shared `runOffCooperativePool` helper; `CNContactStore` itself
/// can't be faked (Apple seals it), so these tests exercise the helper
/// directly.
struct ContactsSourceTests {

    @Test("A synthetic 5k-contact enumeration returns every contact with a unique identifier")
    func fiveThousandSyntheticContactsAllReturn() async throws {
        let contacts = try await runOffCooperativePool { () -> [SystemContact] in
            (0..<5_000).map { index in
                SystemContact(
                    identifier: "synthetic-\(index)",
                    givenName: "Synthetic",
                    familyName: "Contact \(index)",
                    phoneNumbers: [],
                    emailAddresses: []
                )
            }
        }

        #expect(contacts.count == 5_000)
        #expect(Set(contacts.map(\.identifier)).count == 5_000)
    }

    /// The real regression: saturate the pool with `activeProcessorCount`
    /// concurrent off-pool enumerations (one per core — the size the Swift
    /// concurrency cooperative pool is normally provisioned to) and prove a
    /// lightweight task sharing that pool still makes progress while every
    /// one of them is in flight.
    ///
    /// Round 8 empirical correction (three prior verdicts on this test were
    /// all reached by reasoning, not execution, and all three turned out
    /// wrong once actually run against a deliberately-reverted
    /// `runOffCooperativePool`):
    ///
    /// 1. The original version had no deadline at all on the ticks-loop
    ///    responsiveness check, only the 5s `releaseSemaphore` valve inside
    ///    each saturating closure. Reverting `runOffCooperativePool` to run
    ///    `work` inline and running the suite 3 times proved it a slow pass
    ///    every time (~5.0s, exactly the valve), never red — a starved pool
    ///    doesn't hang a deadline-free loop forever, it just delays it
    ///    until the valve frees a thread.
    /// 2. Adding a hard deadline on *only* the ticks check (first via a
    ///    `Task.sleep` raced in a second `withTaskGroup` child task, then
    ///    via a `DispatchSemaphore` + bounded `wait(timeout:)`) still
    ///    stayed 3/3 green. Timestamped instrumentation (temporary, not
    ///    part of this file) showed the real gap wasn't the ticks check —
    ///    it was the `allStarted` loop just above it, which used the
    ///    default 5s-per-signal wait: under saturation, 7 of 8 saturating
    ///    tasks started within milliseconds and the 8th straggled in *just*
    ///    under that 5s window, so `allStarted` (and therefore everything
    ///    after it) squeaked through instead of failing.
    /// 3. A genuine CPU busy-spin saturation mechanism (replacing the
    ///    `DispatchSemaphore.wait` valve, on the theory that a blocked
    ///    syscall gets compensated by this runtime's cooperative-pool
    ///    starvation mitigation in a way pure CPU work wouldn't) turned out
    ///    to be unusable on this actual machine: it's a shared host running
    ///    several other agent lanes' `xcodebuild`/Simulator processes
    ///    concurrently (`uptime` showed a load average of 6.6 on 8 cores
    ///    *before* this test even started), so 8-way CPU-bound saturation
    ///    is dominated by pre-existing host contention rather than by
    ///    `runOffCooperativePool`'s own behavior — both the correct and the
    ///    reverted implementation hit the same ~5s wall identically.
    ///
    /// The actual fix is correction 2, applied precisely: `allStarted`'s own
    /// per-signal wait is tightened from the 5s default to
    /// `startedDeadlineSeconds` (well above what the correct implementation
    /// needs — empirically low tens of milliseconds — and well below the 5s
    /// a saturated pool's straggler needs to limp in). This is the
    /// `DispatchSemaphore.wait`-based saturation from correction 2, not the
    /// CPU-spin from correction 3: it re-proved 3/3 red against the
    /// reverted implementation (see the round 8 report for the actual
    /// failure output) and stayed a fast, clean pass against the real one.
    ///
    /// This still avoids the shortcut that never proved anything: relying
    /// on `Thread.current` identity, since the default Swift concurrency
    /// executor and `DispatchQueue.global` draw worker threads from
    /// overlapping pools, so landing on the same or different OS thread
    /// doesn't say anything either way.
    @Test("Saturating the pool with activeProcessorCount concurrent enumerations keeps it responsive")
    func offCooperativePoolSurvivesFullPoolSaturation() async throws {
        let concurrency = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let startedSemaphore = DispatchSemaphore(value: 0)
        let releaseSemaphore = DispatchSemaphore(value: 0)
        // Safety valve only, not the assertion: if a saturating closure ever
        // runs on a starved cooperative-pool thread (the pre-fix shape), it
        // still returns within 5s so the suite can't hang forever.
        let saturationSafetyValveSeconds = 5.0

        let enumerationTasks = (0..<concurrency).map { _ in
            Task.detached {
                _ = try? await runOffCooperativePool { () -> Int in
                    startedSemaphore.signal()
                    _ = releaseSemaphore.wait(timeout: .now() + saturationSafetyValveSeconds)
                    return 0
                }
            }
        }

        // Tight, not the 5s safety valve above: the correct implementation
        // dispatches every saturating closure off-pool essentially at once
        // (empirically low tens of milliseconds for all `concurrency`
        // signals to arrive), so `startedDeadlineSeconds` gives that a
        // generous multiple of margin while still landing well short of the
        // ~5s a genuinely starved pool's last straggler needs — see
        // correction 2 in the doc comment above for why the 5s default
        // previously let a starved pool "just barely" pass this check.
        let startedDeadlineSeconds = 1.0
        var allStarted = true
        // The `where` still evaluates (and thus waits on) every iteration —
        // only the body, which flips `allStarted`, is conditional.
        for _ in 0..<concurrency
        where waitWithBoundedTimeout(startedSemaphore, seconds: startedDeadlineSeconds) == .timedOut {
            allStarted = false
        }
        #expect(allStarted, """
            every saturating off-pool enumeration should report it started within \
            \(startedDeadlineSeconds)s — a saturated cooperative pool (the shape a \
            regression to running work inline produces) makes at least one straggle \
            well past this, all the way out to the \(saturationSafetyValveSeconds)s \
            safety valve above
            """)

        // While all `concurrency` enumerations are in flight, a lightweight
        // task sharing the cooperative pool must keep making progress
        // *promptly* too. Same reasoning as `startedDeadlineSeconds`: well
        // above what the correct implementation needs, well below the 5s
        // valve.
        let iterations = concurrency * 4
        let ticksDeadlineSeconds = 1.0
        let ticksDeadlineSemaphore = DispatchSemaphore(value: 0)
        let ticksTask = Task.detached {
            for _ in 0..<iterations {
                await Task.yield()
            }
            ticksDeadlineSemaphore.signal()
        }
        let ticksOutcome = waitWithBoundedTimeout(ticksDeadlineSemaphore, seconds: ticksDeadlineSeconds)
        #expect(ticksOutcome == .success, """
            the cooperative pool was still unresponsive after \(ticksDeadlineSeconds)s — \
            \(iterations) Task.yield() iterations should complete in a small fraction of \
            that when runOffCooperativePool truly keeps saturating enumerations off the \
            pool; this shape is what a regression to running work inline looks like
            """)

        for _ in 0..<concurrency { releaseSemaphore.signal() }
        for task in enumerationTasks { _ = await task.value }
        // Only reachable promptly if `ticksOutcome` was `.success` — if it
        // timed out, the ticks task is still running (it isn't cancelled,
        // just no longer waited on with a deadline), so let it finish
        // rather than leaking it past this test's return.
        _ = await ticksTask.value
    }
}

/// `DispatchSemaphore.wait(timeout:)` is unavailable directly from an
/// `async` function body (Swift 6 flags it as a context that shouldn't
/// block a cooperative-pool thread), so the call is boxed in a plain
/// synchronous helper — legal from any context, async or not — exactly
/// like the blocking wait already used inside the off-pool closures above.
private func waitWithBoundedTimeout(
    _ semaphore: DispatchSemaphore,
    seconds: Double = 5
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + seconds)
}
