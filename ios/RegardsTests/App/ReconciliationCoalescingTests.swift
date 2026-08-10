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

    @Test("A burst of rapid store-change notifications coalesces, not one pass per notification")
    func burstOfChangeNotificationsCoalesces() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let source = MutableContactsSource(status: .authorized, contacts: [])
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
                contactsSource: source,
                clock: { self.now }
            )
        )

        await launch.start()
        #expect(launch.reconciliationCount == 1)

        // Fire many notifications back-to-back with no `await` between
        // them, so the coordinator's change-observation `Task` — a
        // separate unstructured task — cannot interleave and consume even
        // one before the burst finishes. Everything after this loop is
        // exercising `changeNotifications()`'s real `.bufferingNewest(1)`
        // policy (`MutableContactsSource` adopts the exact same constant
        // `CNContactsSource` uses), not a fake-invented one.
        let burstSize = 20
        for _ in 0..<burstSize {
            source.simulateChange()
        }

        #expect(await eventually { launch.reconciliationCount >= 2 })
        // A generous ceiling, not an exact count: both the stream's
        // buffering and the coordinator's own single-flight coalescing
        // (the test above) contribute, so pinning one exact number would
        // overspecify which mechanism absorbed the burst. What matters is
        // that 20 rapid triggers didn't produce anywhere near 20 passes.
        #expect(launch.reconciliationCount < burstSize)
    }
}

/// A `ContactsSource` whose `fetchAllContacts()` can be armed to block until
/// explicitly released, so a test can force two reconciliation triggers to
/// genuinely overlap instead of hoping they do.
private final class BlockingFetchContactsSource: ContactsSource, @unchecked Sendable {
    private let lock = NSLock()
    private let contacts: [SystemContact]
    private var fetchCount = 0
    private var shouldBlockNextFetch = false
    private var fetchStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(contacts: [SystemContact]) {
        self.contacts = contacts
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus { .authorized }
    func requestAccess() async throws -> ContactsAuthorizationStatus { .authorized }

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
