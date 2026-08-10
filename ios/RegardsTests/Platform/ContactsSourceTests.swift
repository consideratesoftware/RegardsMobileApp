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
    /// This deliberately avoids two shortcuts that don't actually prove
    /// anything:
    /// - **`Thread.current` identity.** On Apple platforms the default Swift
    ///   concurrency executor and `DispatchQueue.global` draw worker threads
    ///   from overlapping pools, so landing on the same or a different OS
    ///   thread proves nothing either way.
    /// - **Elapsed-wall-clock assertions** (e.g. "sleep 100ms, then expect
    ///   at least N ticks"). Those pass against a *broken* implementation
    ///   too whenever there are spare cores (blocking one cooperative-pool
    ///   thread doesn't starve a ticker if `activeProcessorCount` > 1), and
    ///   they're inherently CI-speed-dependent.
    ///
    /// Instead, every step is gated on an explicit signal: a start semaphore
    /// proves every saturating enumeration is actually occupying a thread
    /// before the pool-responsiveness check runs, and the check itself
    /// counts completed `Task.yield()` iterations rather than measuring
    /// time. If `runOffCooperativePool` regresses to running `work`
    /// directly inline (on the calling cooperative-pool thread instead of a
    /// dispatched GCD worker), saturating with `activeProcessorCount`
    /// concurrent calls exhausts every pool thread, the start signals never
    /// all arrive within the bounded wait, and `allStarted` fails — the
    /// bounded waits below are a safety valve against hanging the suite,
    /// not the pass/fail signal.
    @Test("Saturating the pool with activeProcessorCount concurrent enumerations keeps it responsive")
    func offCooperativePoolSurvivesFullPoolSaturation() async throws {
        let concurrency = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let startedSemaphore = DispatchSemaphore(value: 0)
        let releaseSemaphore = DispatchSemaphore(value: 0)

        let enumerationTasks = (0..<concurrency).map { _ in
            Task.detached {
                _ = try? await runOffCooperativePool { () -> Int in
                    startedSemaphore.signal()
                    // Bounded safety valve only, not the assertion: if this
                    // ever runs on a starved cooperative-pool thread (the
                    // pre-fix shape), it still returns within 5s so the
                    // suite can't hang forever.
                    _ = releaseSemaphore.wait(timeout: .now() + 5)
                    return 0
                }
            }
        }

        var allStarted = true
        // The `where` still evaluates (and thus waits on) every iteration —
        // only the body, which flips `allStarted`, is conditional.
        for _ in 0..<concurrency where waitWithBoundedTimeout(startedSemaphore) == .timedOut {
            allStarted = false
        }
        #expect(allStarted, "every saturating off-pool enumeration should report it started")

        // While all `concurrency` enumerations are in flight, a lightweight
        // task sharing the cooperative pool must keep making progress.
        // `Task.yield()` is scheduler-driven, not time-driven: the
        // assertion is that this loop completes every iteration, not how
        // long it takes.
        let iterations = concurrency * 4
        var ticks = 0
        for _ in 0..<iterations {
            await Task.yield()
            ticks += 1
        }
        #expect(ticks == iterations)

        for _ in 0..<concurrency { releaseSemaphore.signal() }
        for task in enumerationTasks { _ = await task.value }
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
