import Foundation
import Testing
@testable import Regards

/// Launch-time behavior of the notification action consumer: what a buffered
/// action meets when `start()` is still loading, fails, retries, or ends in
/// onboarding, and that exactly one consumer runs. Shares the harness in
/// `NotificationActionHandlingTests.swift`.
extension NotificationActionHandlingTests {
    // MARK: Single consumer and wiring

    /// A failed launch does start the consumer (`start()`'s `defer`), and the
    /// retry reuses it. This pins that the retried launch still has exactly
    /// one working consumer, so one action is applied once. The guard itself
    /// is covered by `consumerStartsOnceWhenStartRunsTwice`.
    @Test("A launch that fails once and is retried consumes actions exactly once")
    func retryAfterFailedLaunchStillConsumesActionsOnce() async throws {
        let attempts = LaunchAttempts()
        let harness = try await Self.harness(
            backend: .mock,
            onboarded: true,
            makeRuntimeFailureCount: 1,
            attempts: attempts
        )
        let contact = try await Self.seed(harness, id: 612, suffix: "retry")
        let barrier = try await Self.seed(harness, id: 613, suffix: "retry-barrier")

        await harness.launch.start()
        #expect(harness.launch.phase == .failed)
        await harness.launch.retry()
        #expect(harness.launch.phase == .ready)
        #expect(await attempts.count == 2)

        harness.fake.send(.caughtUp(contact.id))
        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)

        let logs = try await harness.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10)
        #expect(logs.count == 1)
    }

    /// The first `start()` is still loading when a second one arrives. The
    /// second takes the early-return path, which must not start the consumer
    /// yet: an action tapped before launch would be judged against `.loading`
    /// and dropped, instead of applied once the app is ready.
    @Test(
        "An action buffered before launch is applied once a concurrent second start() and the first both finish",
        arguments: RepositoryContractBackend.allCases
    )
    func bufferedActionAppliesAfterConcurrentStartFinishes(backend: RepositoryContractBackend) async throws {
        let gate = LaunchGate()
        let harness = try await Self.harness(backend: backend, onboarded: true, gate: gate)
        let contact = try await Self.seed(harness, id: 627, suffix: "buffered")
        let barrier = try await Self.seed(harness, id: 628, suffix: "buffered-barrier")
        harness.fake.send(.caughtUp(contact.id))
        let launch = harness.launch

        let first = Task { await launch.start() }
        #expect(await Self.waitFor { await gate.isWaiting }, "the first start() never reached makeRuntime")
        #expect(launch.phase == .loading)
        await launch.start()
        await gate.release()
        await first.value
        #expect(launch.phase == .ready)

        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)
        let logs = try await harness.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10)
        #expect(logs.map(\.source) == [.reminderCaughtUp])
    }

    @Test(
        "An action buffered before a cold launch that ends in onboarding is dropped",
        arguments: RepositoryContractBackend.allCases
    )
    func coldLaunchActionDuringOnboardingIsDropped(backend: RepositoryContractBackend) async throws {
        let harness = try await Self.harness(backend: backend, onboarded: false)
        let contact = try await Self.seed(harness, id: 629, suffix: "cold-onboarding")
        let barrier = try await Self.seed(harness, id: 630, suffix: "cold-onboarding-barrier")
        harness.fake.send(.caughtUp(contact.id))

        await harness.launch.start()
        #expect(harness.launch.phase == .onboarding)
        let handled = await Self.waitFor { harness.launch.handledNotificationActionCount == 1 }
        #expect(handled, "the buffered action was never judged")
        await harness.launch.continueWithoutContacts()
        #expect(harness.launch.phase == .ready)

        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)
        try await Self.expectUntouched(harness, contact)
    }

    /// A second `start()` on a launched coordinator (the root view's task can
    /// run again) takes the early-return path, which calls the consumer-start
    /// point again. Without the `notificationActionTask == nil` guard a second
    /// consumer would join the stream and handle actions concurrently with the
    /// first, so they would no longer be applied in order.
    @Test(
        "Calling start() a second time reaches the consumer start again but consumes actions exactly once",
        arguments: RepositoryContractBackend.allCases
    )
    func consumerStartsOnceWhenStartRunsTwice(backend: RepositoryContractBackend) async throws {
        let harness = try await Self.readyHarness(backend: backend)
        let contact = try await Self.seed(harness, id: 614, suffix: "start-twice")
        let barrier = try await Self.seed(harness, id: 615, suffix: "start-twice-barrier")

        await harness.launch.start()

        harness.fake.send(.caughtUp(contact.id))
        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)
        let logs = try await harness.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10)
        #expect(logs.count == 1)
    }

    @Test("Production launch wires the shared notification adapter")
    func productionWiresSharedAdapter() throws {
        let dependencies = try #require(AppLaunchCoordinator.production().dependencies)

        #expect((dependencies.notifications as AnyObject?) === UserNotificationsAdapter.shared)
    }
}
