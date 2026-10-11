import Foundation
import Testing
@testable import Regards

/// TF-06 slice 2. Notification actions (Caught up, Snooze 1 week) arrive on
/// `NotificationScheduling.actions` and the coordinator applies them to
/// persisted state through the same sequence the view models use. Tests drive
/// them through `DebugNotificationScheduling.send(_:)`, so none touches the
/// real notification center.
///
/// The coordinator handles actions serially, so a test that needs to know an
/// earlier action finished sends a later action for a different, eligible
/// contact ("the barrier") and waits for that one's effect. There are no
/// sleeps. `waitFor` polls with `Task.yield()`, the same convention as
/// `eventually`, but for conditions that need an `await`.
@MainActor
struct NotificationActionHandlingTests {
    /// Whole seconds, so repository round-trips compare exactly. Pinned to
    /// 2027-03-10 10:00 in Los Angeles: seven calendar days later crosses the
    /// 2027-03-14 spring-forward, so a 7 * 86_400 s push would land an hour
    /// off in the window's zone.
    private static let windowZone = TimeZone(identifier: "America/Los_Angeles")!
    private static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = windowZone
        return calendar.date(from: DateComponents(year: 2027, month: 3, day: 10, hour: 10))!
    }()
    private static var sevenCalendarDaysLater: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = windowZone
        return calendar.date(from: DateComponents(year: 2027, month: 3, day: 17, hour: 10))!
    }

    private struct Harness {
        let launch: AppLaunchCoordinator
        let fake: DebugNotificationScheduling
        let repositories: RepositoryContractRepositories
        let scheduler: SchedulingPass
    }

    // MARK: Caught up

    @Test(
        "Caught up from a notification logs one interaction, moves lastInteractedAt to now and clears the snooze",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpLogsInteractionAndClearsSnooze(backend: RepositoryContractBackend) async throws {
        let harness = try await Self.readyHarness(backend: backend)
        let contact = try await Self.seed(harness, id: 601, suffix: "caught-up")
        try await harness.scheduler.snooze(contactId: contact.id)
        #expect(try await harness.scheduler.pendingSnoozeDate(contactId: contact.id) != nil)

        harness.fake.send(.caughtUp(contact.id))

        let settled = await Self.waitFor {
            try await harness.repositories.contacts.fetch(id: contact.id)?.lastInteractedAt == Self.now
        }
        #expect(settled)
        let logs = try await harness.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10)
        #expect(logs.map(\.source) == [.reminderCaughtUp])
        #expect(logs.first?.occurredAt == Self.now)
        #expect(try await harness.scheduler.pendingSnoozeDate(contactId: contact.id) == nil)
    }

    @Test(
        "A failed interaction write restores the snooze the Caught up action had cleared",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpFailureRestoresClearedSnooze(backend: RepositoryContractBackend) async throws {
        let harness = try await Self.readyHarness(backend: backend, interactions: StubInteractionRepository.failing())
        let contact = try await Self.seed(harness, id: 602, suffix: "caught-up-fails")
        let barrier = try await Self.seed(harness, id: 603, suffix: "caught-up-fails-barrier")
        try await harness.scheduler.snooze(contactId: contact.id)
        let snoozedUntil = try #require(try await harness.scheduler.pendingSnoozeDate(contactId: contact.id))

        harness.fake.send(.caughtUp(contact.id))
        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)

        #expect(try await harness.scheduler.pendingSnoozeDate(contactId: contact.id) == snoozedUntil)
        let after = try #require(try await harness.repositories.contacts.fetch(id: contact.id))
        #expect(after.lastInteractedAt == contact.lastInteractedAt)
    }

    // MARK: Snooze

    @Test(
        "Snooze from a notification pushes the reminder seven calendar days in the window zone",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeActionPushesSevenCalendarDays(backend: RepositoryContractBackend) async throws {
        let harness = try await Self.readyHarness(backend: backend)
        let contact = try await Self.seed(harness, id: 604, suffix: "snooze")

        harness.fake.send(.snooze(contact.id))

        let settled = await Self.waitFor {
            try await harness.scheduler.pendingSnoozeDate(contactId: contact.id) != nil
        }
        #expect(settled)
        #expect(try await harness.scheduler.pendingSnoozeDate(contactId: contact.id) == Self.sevenCalendarDaysLater)
        // Decision #31: Snooze logs nothing and leaves lastInteractedAt alone.
        #expect(try await harness.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10).isEmpty)
        let after = try #require(try await harness.repositories.contacts.fetch(id: contact.id))
        #expect(after.lastInteractedAt == contact.lastInteractedAt)
    }

    @Test(
        "Two Snooze actions for one contact leave a single pending row",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeActionTwiceKeepsOneRow(backend: RepositoryContractBackend) async throws {
        let harness = try await Self.readyHarness(backend: backend)
        let contact = try await Self.seed(harness, id: 605, suffix: "snooze-twice")
        let barrier = try await Self.seed(harness, id: 606, suffix: "snooze-twice-barrier")

        harness.fake.send(.snooze(contact.id))
        harness.fake.send(.snooze(contact.id))
        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)

        let pending = try await harness.repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending.first?.scheduledFor == Self.sevenCalendarDaysLater)
    }

    // MARK: Ineligible and early actions

    /// Each case breaks one eligibility rule. Deleting only the `tracked`
    /// check or only the `cadenceDays` check in the handler turns its case
    /// red. The archived case is weaker: `SchedulingPass.snooze` and
    /// `InteractionLogging` also check `isActive`, so it pins the whole chain
    /// and would stay green if the handler's own `isActive` check went.
    enum IneligibleContact: String, CaseIterable, Sendable {
        case archived
        case untrackedWithCadence
        case trackedWithoutCadence
    }

    @Test(
        "Actions for a contact that is archived, untracked, or without a cadence write nothing",
        arguments: RepositoryContractBackend.allCases, IneligibleContact.allCases
    )
    func actionForIneligibleContactWritesNothing(
        backend: RepositoryContractBackend, kind: IneligibleContact
    ) async throws {
        let harness = try await Self.readyHarness(backend: backend)
        let ineligible = switch kind {
        case .archived:
            try await Self.seed(harness, id: 607, suffix: "archived", archivedAt: Self.now)
        case .untrackedWithCadence:
            try await Self.seed(harness, id: 608, suffix: "untracked", tracked: false, cadenceDays: 14)
        case .trackedWithoutCadence:
            try await Self.seed(harness, id: 609, suffix: "no-cadence", cadenceDays: nil)
        }
        let bystander = try await Self.seed(harness, id: 616, suffix: "bystander")
        let barrier = try await Self.seed(harness, id: 617, suffix: "ineligible-barrier")

        harness.fake.send(.caughtUp(ineligible.id))
        harness.fake.send(.snooze(ineligible.id))
        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)

        let logs = try await harness.repositories.interactions.fetchRecent(forContact: ineligible.id, limit: 10)
        #expect(logs.isEmpty)
        #expect(try await harness.repositories.reminders.fetchPending(forContact: ineligible.id).isEmpty)
        let after = try #require(try await harness.repositories.contacts.fetch(id: ineligible.id))
        #expect(after.lastInteractedAt == ineligible.lastInteractedAt)
        try await Self.expectUntouched(harness, bystander)
    }

    @Test(
        "An action that arrives during onboarding is dropped, not applied once onboarding finishes",
        arguments: RepositoryContractBackend.allCases
    )
    func actionDuringOnboardingIsDropped(backend: RepositoryContractBackend) async throws {
        let harness = try await Self.harness(backend: backend, onboarded: false)
        let contact = try await Self.seed(harness, id: 610, suffix: "onboarding")
        let barrier = try await Self.seed(harness, id: 611, suffix: "onboarding-barrier")
        await harness.launch.start()
        #expect(harness.launch.phase == .onboarding)

        harness.fake.send(.caughtUp(contact.id))
        // Wait until the consumer has handled (here, dropped) the action, so
        // onboarding can't finish before it is judged against the phase.
        let handled = await Self.waitFor { harness.launch.handledNotificationActionCount == 1 }
        #expect(handled, "the action was never handled")
        #expect(harness.launch.phase == .onboarding)
        await harness.launch.continueWithoutContacts()
        #expect(harness.launch.phase == .ready)

        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)

        #expect(try await harness.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10).isEmpty)
        let after = try #require(try await harness.repositories.contacts.fetch(id: contact.id))
        #expect(after.lastInteractedAt == contact.lastInteractedAt)
    }

    /// The launch-failure screen has no runtime, so an action tapped there
    /// can't be applied. It must not wait in the stream and fire after a
    /// retry succeeds, when the user is looking at something else.
    @Test(
        "An action tapped while the launch-failure screen is showing is dropped, not applied after a retry",
        arguments: RepositoryContractBackend.allCases
    )
    func actionOnLaunchFailureScreenIsDroppedAfterRetry(backend: RepositoryContractBackend) async throws {
        let harness = try await Self.harness(backend: backend, onboarded: true, makeRuntimeFailureCount: 1)
        let contact = try await Self.seed(harness, id: 618, suffix: "failure-screen")
        let bystander = try await Self.seed(harness, id: 619, suffix: "failure-screen-bystander")
        let barrier = try await Self.seed(harness, id: 620, suffix: "failure-screen-barrier")
        try await harness.scheduler.snooze(contactId: contact.id)
        let snoozedUntil = try #require(try await harness.scheduler.pendingSnoozeDate(contactId: contact.id))

        await harness.launch.start()
        #expect(harness.launch.phase == .failed)
        #expect(harness.launch.runtime == nil)
        harness.fake.send(.caughtUp(contact.id))
        // Wait until the consumer has judged the action against the failure
        // screen. A retry that raced ahead of it would let the action run
        // against a ready runtime.
        let dropped = await Self.waitFor { harness.launch.handledNotificationActionCount == 1 }
        #expect(dropped, "the action was never handled")
        await harness.launch.retry()
        #expect(harness.launch.phase == .ready)

        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)

        #expect(try await harness.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10).isEmpty)
        let after = try #require(try await harness.repositories.contacts.fetch(id: contact.id))
        #expect(after.lastInteractedAt == contact.lastInteractedAt)
        #expect(try await harness.scheduler.pendingSnoozeDate(contactId: contact.id) == snoozedUntil)
        try await Self.expectUntouched(harness, bystander)
    }

    // MARK: Single consumer and wiring

    /// A failed first attempt never reaches the consumer-start point, so this
    /// pins that a retry still ends up with one working consumer, not that the
    /// single-consumer guard holds. `consumerStartsOnceWhenStartRunsTwice`
    /// covers the guard.
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

    /// A second `start()` on a launched coordinator (the root view's task can
    /// run again) takes the early-return path, which calls the consumer-start
    /// point again. Without the `notificationActionTask == nil` guard a second
    /// iterator would join the stream, which traps.
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

extension NotificationActionHandlingTests {
    // MARK: Helpers

    private actor LaunchAttempts {
        private(set) var count = 0
        func record() -> Int {
            count += 1
            return count
        }
    }

    private struct LaunchFailure: Error {}

    /// A started, onboarded coordinator over `backend`, optionally with a
    /// replacement interaction repository.
    private static func readyHarness(
        backend: RepositoryContractBackend,
        interactions: (any InteractionRepository)? = nil
    ) async throws -> Harness {
        let harness = try await Self.harness(backend: backend, onboarded: true, interactions: interactions)
        await harness.launch.start()
        #expect(harness.launch.phase == .ready)
        return harness
    }

    /// Builds the coordinator without starting it. `makeRuntimeFailureCount`
    /// makes the first N launch attempts throw.
    private static func harness(
        backend: RepositoryContractBackend,
        onboarded: Bool,
        interactions: (any InteractionRepository)? = nil,
        makeRuntimeFailureCount: Int = 0,
        attempts: LaunchAttempts = LaunchAttempts()
    ) async throws -> Harness {
        let now = Self.now
        let repositories = try backend.makeRepositories()
        let environment = AppEnvironment(
            contacts: repositories.contacts,
            groups: repositories.groups,
            reminders: repositories.reminders,
            interactions: interactions ?? repositories.interactions,
            window: repositories.window,
            profile: repositories.profile
        )
        try await environment.profile.save(
            UserProfile(
                onboardingCompletedAt: onboarded ? now : nil,
                entitlementTier: .trial,
                entitlementRefreshedAt: now,
                trialStartedAt: now
            )
        )
        var userCalendar = Calendar(identifier: .gregorian)
        userCalendar.timeZone = windowZone
        let runtime = AppRuntime(
            environment: environment,
            window: ReminderWindow.defaultV1(timezone: windowZone),
            userCalendar: userCalendar,
            clock: { now }
        )
        let fake = DebugNotificationScheduling()
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: {
                    let attempt = await attempts.record()
                    if attempt <= makeRuntimeFailureCount { throw LaunchFailure() }
                    return runtime
                },
                contactsSource: ScriptedLaunchContactsSource(status: onboarded ? .denied : .notDetermined),
                clock: { now },
                notifications: fake
            )
        )
        return Harness(
            launch: launch,
            fake: fake,
            repositories: repositories,
            scheduler: runtime.scheduler
        )
    }

    /// Stores a contact and returns it as read back, so later comparisons use
    /// the persisted values (timestamps are stored to the second).
    private static func seed(
        _ harness: Harness,
        id: Int,
        suffix: String,
        tracked: Bool = true,
        cadenceDays: Int? = 14,
        archivedAt: Date? = nil
    ) async throws -> Contact {
        var contact = contractContact(
            id: try contractUUID(id), suffix: suffix, tracked: tracked, archivedAt: archivedAt
        )
        contact.cadenceDays = cadenceDays
        try await harness.repositories.contacts.upsert(contact)
        return try #require(try await harness.repositories.contacts.fetch(id: contact.id))
    }

    /// A contact no action targeted still has no log, no pending row, and its
    /// original `lastInteractedAt`.
    private static func expectUntouched(_ harness: Harness, _ contact: Contact) async throws {
        #expect(try await harness.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10).isEmpty)
        #expect(try await harness.repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
        let after = try #require(try await harness.repositories.contacts.fetch(id: contact.id))
        #expect(after.lastInteractedAt == contact.lastInteractedAt)
    }

    /// Polls `condition` with `Task.yield()` between attempts, up to a fixed
    /// iteration count, instead of sleeping.
    private static func waitFor(_ condition: () async throws -> Bool) async -> Bool {
        for _ in 0..<3_000 {
            if (try? await condition()) == true { return true }
            await Task.yield()
        }
        return (try? await condition()) == true
    }

    /// The barrier action is a Snooze for `contactId`; once its pending row
    /// exists, every earlier action has been handled.
    private static func expectBarrierSettled(_ harness: Harness, _ contactId: UUID) async {
        let settled = await waitFor {
            try await harness.scheduler.pendingSnoozeDate(contactId: contactId) != nil
        }
        #expect(settled, "the barrier action was never applied")
    }
}
