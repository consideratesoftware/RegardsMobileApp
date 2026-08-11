import Foundation
import Testing
@testable import Regards

/// Fix 9: overlapping reconciliation triggers must coalesce into a single
/// in-flight `ContactsReconciler.reconcile()` pass rather than running two
/// concurrently against the same database.
@MainActor
struct ReconciliationCoalescingTests {
    let now = Date(timeIntervalSince1970: 1_785_600_000)

    @Test("A foreground trigger racing an in-flight reconciliation coalesces into one extra pass")
    func overlappingTriggersCoalesceIntoOnePass() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let source = BlockingFetchContactsSource(contacts: [
            SystemContact(identifier: "id-1", givenName: "One", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
                contactsSource: source,
                clock: { self.now }
            )
        )

        await launch.start()
        #expect(launch.phase == .ready)
        // `start()` already ran and awaited reconciliation pass #1 in full
        // (the source isn't armed to block yet), so the count starts at 1.
        #expect(launch.reconciliationCount == 1)

        // Arm the source to block the *next* `fetchAllContacts()` call, then
        // kick off pass #2 without awaiting it yet.
        source.armBlock()
        let firstForeground = Task { await launch.handleSceneActivation() }
        await source.waitUntilFetchStarts()
        #expect(source.fetchCountValue() == 2)

        // A second foreground arrives while pass #2 is genuinely inside
        // `fetchAllContacts()` — this must coalesce into pass #2's task
        // (registering as pending, not starting a concurrent pass #3).
        // `reconciliationCoalesceCount` is a direct signal of that join, so
        // this wait is gated on an actual state transition, not on
        // elapsed time or a guessed number of yields.
        let secondForeground = Task { await launch.handleSceneActivation() }
        #expect(await eventually { launch.reconciliationCoalesceCount == 1 })

        // Neither foreground call has produced a second concurrent fetch —
        // the source has been asked to enumerate exactly once since the
        // block was armed, proving the two triggers never overlapped a
        // `fetchAllContacts()` call.
        #expect(source.fetchCountValue() == 2)

        source.releaseFetch()
        await firstForeground.value
        await secondForeground.value

        // Releasing lets pass #2 finish, then the coalesced bit runs
        // exactly one more pass (#3) — covering the second trigger — before
        // the loop exits. Total: 3 passes for 3 triggers (start, and two
        // overlapping foregrounds collapsed to one extra), never two
        // concurrent `fetchAllContacts()` calls.
        #expect(launch.reconciliationCount == 3)
        #expect(source.fetchCountValue() == 3)
        #expect(launch.reconciliationCoalesceCount == 1)
    }

    /// Deliberately doesn't use `eventually { reconciliationCount >= 2 }`
    /// followed by a `< burstSize` check: that stops the instant pass #2
    /// lands, which happens the moment the *first* buffered notification is
    /// consumed — under a regression to unbounded buffering, the other 18
    /// would still be sitting queued, unconsumed, and the count would
    /// happen to read 2-3 at that exact moment too, passing by accident.
    /// Instead this lands the whole burst *while a pass is genuinely
    /// in-flight* (the same deterministic shape as the overlapping-trigger
    /// test above), releases, and asserts the exact settled count — which
    /// only stays low if the buffering policy really coalesced the burst
    /// before the consumer ever got to it.
    @Test("A burst of rapid store-change notifications coalesces, not one pass per notification")
    func burstOfChangeNotificationsCoalesces() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let source = BlockingFetchContactsSource(contacts: [])
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
                contactsSource: source,
                clock: { self.now }
            )
        )

        await launch.start()
        #expect(launch.reconciliationCount == 1)

        // One notification kicks off pass #2 and is armed to block inside
        // `fetchAllContacts()`, so it's still genuinely in flight — not yet
        // back at `for await` listening for the next stream value — when
        // the burst below lands.
        source.armBlock()
        source.simulateChange()
        await source.waitUntilFetchStarts()
        #expect(source.fetchCountValue() == 2)

        // The rest of the burst arrives while pass #2 is blocked. With
        // `.bufferingNewest(1)` this collapses to at most one buffered
        // value waiting for the consumer's next iteration, regardless of
        // how many notifications land here.
        let burstSize = 20
        for _ in 1..<burstSize {
            source.simulateChange()
        }

        source.releaseFetch()

        // Pass #2 finishes, then the consumer loop's next `for await`
        // iteration picks up whatever the buffering policy left it: exactly
        // one coalesced value (fixed) or up to 19 still-queued ones
        // (regressed to unbounded). Draining to quiescence — rather than
        // stopping at the first moment the count happens to equal the
        // expected value — is what makes this discriminate: a broken policy
        // would keep advancing past 3 after any single snapshot check.
        let settledCount = await drainedCount(of: launch)

        #expect(settledCount == 3)
        #expect(source.fetchCountValue() == 3)
    }

    /// Fix 6: `beginObservingContactStoreChanges` must run *before*
    /// `start()`'s own launch reconcile, not after — otherwise a change
    /// notification landing while that first (possibly long, per R25) pass
    /// is still in flight has no stream to land on yet and is lost for
    /// good, rather than merely delayed until the pass finishes.
    @Test("A store-change notification landing during the launch reconcile itself still coalesces")
    func storeChangeDuringLaunchReconcileCoalesces() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let source = BlockingFetchContactsSource(contacts: [])
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
                contactsSource: source,
                clock: { self.now }
            )
        )

        // Armed *before* `start()` runs at all, so the pass this blocks is
        // `start()`'s own launch reconcile — not a later foreground/
        // store-change pass, which the tests above already cover.
        source.armBlock()
        let startTask = Task { await launch.start() }
        await source.waitUntilFetchStarts()
        #expect(source.fetchCountValue() == 1)

        source.simulateChange()
        // Under the pre-fix ordering, `beginObservingContactStoreChanges`
        // hasn't run yet at this point (it only ran *after* `reconcileNow`
        // returned), so `changeContinuation` would still be nil and this
        // call a silent no-op — this wait would time out and the coalesce
        // count would never move off 0.
        #expect(await eventually { launch.reconciliationCoalesceCount == 1 })

        source.releaseFetch()
        await startTask.value

        #expect(launch.phase == .ready)
        #expect(launch.reconciliationCount == 2)
        #expect(source.fetchCountValue() == 2)
    }
}

/// Polls `launch.reconciliationCount` until it settles: `reconciliationTask`
/// — `AppLaunchCoordinator`'s own "isReconciling" gate (`reconcileNow`'s doc
/// comment) — reads `nil` *and* the count hasn't moved across
/// `stableCyclesRequired` consecutive pump cycles in a row. Bounded by a
/// wall-clock `deadline`, not an iteration count.
///
/// Round 11 hardening: the original version yielded between reads
/// (`Task.yield()` only, the same shape `eventually` uses) and reproduced a
/// real flake under full-suite parallel load — `settledCount` landed on 1
/// instead of 3, meaning it declared quiescence in the gap *between* pass #2
/// finishing and pass #3 starting. That gap is real and expected here (see
/// `burstOfChangeNotificationsCoalesces`'s comment): after `releaseFetch()`,
/// `beginObservingContactStoreChanges`'s consumer loop has to actually get
/// scheduled again to pick the one buffered notification back up and call
/// `reconcileNow` for pass #3, and a bare `Task.yield()` doesn't reliably
/// give that suspended `Task` a real scheduling turn under contention.
/// Fixed by pumping the run loop each cycle — the same primitive
/// `eventuallyPumpingRunLoop` uses (`RegardsTests/Support/Eventually.swift`)
/// — so a scheduling turn is a real event, not a hope, and by only counting
/// a cycle toward "stable" while `reconciliationTask == nil`, so a pass
/// genuinely in flight can never be mistaken for quiescence.
///
/// Round 12 correction: that fix still capped the *number of pump cycles*
/// (`maxIterations`) rather than real time, and PR #48's CI caught exactly
/// what that encodes — local machine timing. Each pump cycle blocks for a
/// fixed slice of wall-clock time (`pumpRunLoopBriefly`), but how much
/// *real* elapsed time an in-flight pass needs before the next cycle sees
/// it finish depends on how contended the runner is; a contended CI runner
/// needing more cycles than a fast local machine isn't a bug; capping
/// cycles bakes in an assumption about how fast "the runner" is. `deadline`
/// replaces that cap with a wall-clock backstop instead — generous on
/// purpose, since it exists only to fail a genuinely-hung drain rather than
/// to bound how long a slow-but-real drain gets. That costs nothing on the
/// green path: this suite settles in well under a second even locally, and
/// the assertion that follows compares the exact settled count, which is
/// load-independent regardless of how long it took to reach it.
@MainActor
private func drainedCount(
    of launch: AppLaunchCoordinator,
    stableCyclesRequired: Int = 3,
    deadline: TimeInterval = 60
) async -> Int {
    let cutoff = Date().addingTimeInterval(deadline)
    var lastCount = launch.reconciliationCount
    var stableStreak = 0
    while stableStreak < stableCyclesRequired, Date() < cutoff {
        await Task.yield()
        pumpRunLoopBriefly()
        let current = launch.reconciliationCount
        if current == lastCount, launch.reconciliationTask == nil {
            stableStreak += 1
        } else {
            stableStreak = 0
            lastCount = current
        }
    }
    return lastCount
}

/// A `ContactsSource` whose `fetchAllContacts()` can be armed to block until
/// explicitly released, so a test can force two reconciliation triggers to
/// genuinely overlap instead of hoping they do. Also drives
/// `changeNotifications()` explicitly, using the exact same
/// `.bufferingNewest(1)` policy `CNContactsSource` uses in production, for
/// tests that need both a controllable block *and* controllable
/// store-change notifications at once.
private final class BlockingFetchContactsSource: ContactsSource, @unchecked Sendable {
    private let lock = NSLock()
    private let contacts: [SystemContact]
    private var fetchCount = 0
    private var shouldBlockNextFetch = false
    private var fetchStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var changeContinuation: AsyncStream<Void>.Continuation?

    init(contacts: [SystemContact]) {
        self.contacts = contacts
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus { .authorized }
    func requestAccess() async throws -> ContactsAuthorizationStatus { .authorized }

    func changeNotifications() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: changeNotificationBufferingPolicy) { continuation in
            lock.withLock { self.changeContinuation = continuation }
        }
    }

    func simulateChange() {
        lock.withLock { changeContinuation }?.yield()
    }

    func fetchAllContacts() async throws -> [SystemContact] {
        let shouldBlock = lock.withLock {
            fetchCount += 1
            let blockThisCall = shouldBlockNextFetch
            shouldBlockNextFetch = false
            return blockThisCall
        }
        guard shouldBlock else { return contacts }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                fetchStarted = true
                startWaiter?.resume()
                startWaiter = nil
                releaseWaiter = continuation
            }
        }
        return contacts
    }

    func armBlock() {
        lock.withLock {
            shouldBlockNextFetch = true
            fetchStarted = false
        }
    }

    /// Nit: bounded rather than an unconditional `await` — if a future
    /// regression in the code under test means `fetchAllContacts()` is
    /// never actually called, this used to hang the whole suite instead of
    /// failing the one test that needed it to be called. The watchdog
    /// forces the continuation closed and records a failure past `timeout`;
    /// the common (passing) path cancels the watchdog once the real start
    /// signal arrives, well under it.
    ///
    /// The `fetchStarted` check and the `startWaiter` install happen under a
    /// single lock acquisition, because `fetchAllContacts()` runs off the
    /// main actor: reading the flag, releasing the lock, and only then
    /// installing the waiter leaves a window where the fetch's own lock
    /// section sees `startWaiter == nil`, resumes nobody, and the waiter
    /// installed a moment later waits for a signal that has already been
    /// sent. That lost wakeup is what fails this test at exactly `timeout`.
    func waitUntilFetchStarts(timeout: Duration = .seconds(10)) async {
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            let leftoverWaiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let waiter = startWaiter
                startWaiter = nil
                return waiter
            }
            if let leftoverWaiter {
                Issue.record("waitUntilFetchStarts timed out after \(timeout) — fetchAllContacts() was never called")
                leftoverWaiter.resume()
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyStarted = lock.withLock { () -> Bool in
                guard !fetchStarted else { return true }
                startWaiter = continuation
                return false
            }
            if alreadyStarted { continuation.resume() }
        }
        watchdog.cancel()
    }

    func releaseFetch() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let waiter = releaseWaiter
            releaseWaiter = nil
            return waiter
        }
        waiter?.resume()
    }

    func fetchCountValue() -> Int {
        lock.withLock { fetchCount }
    }
}
