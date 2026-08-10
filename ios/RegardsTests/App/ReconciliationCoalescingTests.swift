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
}

/// Polls `launch.reconciliationCount`, yielding between reads, until it
/// stops changing across `stableIterations` consecutive checks (bounded by
/// `maxIterations` so a genuinely-never-settling count fails the test
/// instead of hanging it). All work in this suite is in-memory GRDB with no
/// real I/O latency, so a real pass reliably completes well inside this
/// window — a plateau this long is quiescence, not a gap between passes.
@MainActor
private func drainedCount(
    of launch: AppLaunchCoordinator,
    stableIterations: Int = 50,
    maxIterations: Int = 2_000
) async -> Int {
    var lastCount = launch.reconciliationCount
    var stableStreak = 0
    var iterations = 0
    while stableStreak < stableIterations, iterations < maxIterations {
        await Task.yield()
        iterations += 1
        let current = launch.reconciliationCount
        if current == lastCount {
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

    func waitUntilFetchStarts() async {
        let alreadyStarted = lock.withLock { fetchStarted }
        guard !alreadyStarted else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { startWaiter = continuation }
        }
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
