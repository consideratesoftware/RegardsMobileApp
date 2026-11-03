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
    static let windowZone = TimeZone(identifier: "America/Los_Angeles")!
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = windowZone
        return calendar.date(from: DateComponents(year: 2027, month: 3, day: 10, hour: 10))!
    }()
    private static var sevenCalendarDaysLater: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = windowZone
        return calendar.date(from: DateComponents(year: 2027, month: 3, day: 17, hour: 10))!
    }
    /// The first slot of the default weekday window (12:00-13:00) that opens
    /// at or after `sevenCalendarDaysLater`, a Wednesday.
    private static var snoozeSlot: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = windowZone
        return calendar.date(from: DateComponents(year: 2027, month: 3, day: 17, hour: 12))!
    }

    struct Harness {
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

    // The two Snooze tests below pin the date math: the floor is the tap time
    // plus 7 calendar days in the window zone, and the row's `scheduledFor` is
    // the first slot of the contact's window at or after it (R57).

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
        #expect(try await harness.scheduler.pendingSnoozeDate(contactId: contact.id) == Self.snoozeSlot)
        let row = try #require(try await harness.repositories.reminders.fetchPending(forContact: contact.id).first)
        #expect(row.snoozedUntil == Self.sevenCalendarDaysLater)
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
        #expect(pending.first?.snoozedUntil == Self.sevenCalendarDaysLater)
        #expect(pending.first?.scheduledFor == Self.snoozeSlot)
    }

    // MARK: Ineligible and early actions

    /// Each case breaks one eligibility rule. Caught up is judged by
    /// `recordInteraction(.caughtUpFromNotification)` through
    /// `isCadenceEligible`, Snooze by `SchedulingPass.snooze`. The archived
    /// case is weaker: `InteractionLogging` also checks `isActive`, so it
    /// would stay green if `isCadenceEligible` ignored it.
    enum IneligibleContact: String, CaseIterable, Sendable {
        case archived
        case untrackedWithCadence
        case trackedWithoutCadence
        case trackedWithZeroCadence
    }

    @Test(
        "Actions for a contact that is archived, untracked, or without a positive cadence write nothing",
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
        case .trackedWithZeroCadence:
            try await Self.seed(harness, id: 627, suffix: "zero-cadence", cadenceDays: 0)
        }
        let bystander = try await Self.seed(harness, id: 616, suffix: "bystander")
        let barrier = try await Self.seed(harness, id: 617, suffix: "ineligible-barrier")

        harness.fake.send(.caughtUp(ineligible.id))
        harness.fake.send(.snooze(ineligible.id))
        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)

        try await Self.expectUntouched(harness, ineligible, ineligible: true)
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

    @Test(
        "An action for a contact that no longer exists writes nothing",
        arguments: RepositoryContractBackend.allCases
    )
    func actionForMissingContactWritesNothing(backend: RepositoryContractBackend) async throws {
        let harness = try await Self.readyHarness(backend: backend)
        let missingId = try contractUUID(699)
        let bystander = try await Self.seed(harness, id: 621, suffix: "missing-bystander")
        let barrier = try await Self.seed(harness, id: 622, suffix: "missing-barrier")

        harness.fake.send(.caughtUp(missingId))
        harness.fake.send(.snooze(missingId))
        harness.fake.send(.snooze(barrier.id))
        await Self.expectBarrierSettled(harness, barrier.id)

        #expect(try await harness.repositories.interactions.fetchRecent(forContact: missingId, limit: 10).isEmpty)
        #expect(try await harness.repositories.reminders.fetchPending(forContact: missingId).isEmpty)
        try await Self.expectUntouched(harness, bystander)
    }

    @Test("A contact read that throws writes nothing, and the next action is still handled")
    func contactReadFailureWritesNothingAndConsumerContinues() async throws {
        let contacts = StubContactRepository()
        // All three stubs: the mock backend's interaction store rejects a log
        // for a contact that only exists in the stub contact repository.
        let harness = try await Self.readyHarness(
            backend: .mock,
            contacts: contacts,
            reminders: StubReminderRepository(),
            interactions: StubInteractionRepository()
        )
        let failed = try await Self.seed(harness, id: 623, suffix: "read-fails")
        let next = try await Self.seed(harness, id: 624, suffix: "read-fails-next")
        await contacts.armFetchFailures(1)

        harness.fake.send(.caughtUp(failed.id))
        harness.fake.send(.caughtUp(next.id))

        // Poll with `fetchAll()`, not `fetch(id:)`: the armed failure belongs
        // to the handler's first read, and a polling `fetch` would use it up.
        let handledNext = await Self.waitFor {
            try await harness.repositories.contacts.fetchAll()
                .first { $0.id == next.id }?.lastInteractedAt == Self.now
        }
        #expect(handledNext, "the action after the failed read was never applied")
        try await Self.expectUntouched(harness, failed)
        let logs = try await harness.repositories.interactions.fetchRecent(forContact: next.id, limit: 10)
        #expect(logs.count == 1)
    }

    @Test("A Snooze whose write throws leaves no row, and the next action is still handled")
    func snoozeWriteFailureLeavesNoRowAndConsumerContinues() async throws {
        let harness = try await Self.readyHarness(backend: .mock, reminders: StubReminderRepository.failingUpsert())
        let failed = try await Self.seed(harness, id: 625, suffix: "snooze-fails")
        let next = try await Self.seed(harness, id: 626, suffix: "snooze-fails-next")

        harness.fake.send(.snooze(failed.id))
        harness.fake.send(.caughtUp(next.id))

        let handledNext = await Self.waitFor {
            try await harness.repositories.contacts.fetch(id: next.id)?.lastInteractedAt == Self.now
        }
        #expect(handledNext, "the action after the failed Snooze was never applied")
        try await Self.expectUntouched(harness, failed)
    }
}

extension NotificationActionHandlingTests {
    // MARK: Helpers

    actor LaunchAttempts {
        private(set) var count = 0
        func record() -> Int {
            count += 1
            return count
        }
    }

    struct LaunchFailure: Error {}

    /// Holds `makeRuntime` until the test releases it, so a test can act
    /// while the first `start()` is still loading.
    actor LaunchGate {
        private(set) var isWaiting = false
        private var isReleased = false
        private var continuation: CheckedContinuation<Void, Never>?

        func pause() async {
            isWaiting = true
            guard !isReleased else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            isReleased = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// A started, onboarded coordinator over `backend`, optionally with
    /// replacement contact, reminder, or interaction repositories.
    static func readyHarness(
        backend: RepositoryContractBackend,
        contacts: (any ContactRepository)? = nil,
        reminders: (any ReminderRepository)? = nil,
        interactions: (any InteractionRepository)? = nil
    ) async throws -> Harness {
        let harness = try await Self.harness(
            backend: backend,
            onboarded: true,
            contacts: contacts,
            reminders: reminders,
            interactions: interactions
        )
        await harness.launch.start()
        #expect(harness.launch.phase == .ready)
        return harness
    }

    /// Builds the coordinator without starting it. `makeRuntimeFailureCount`
    /// makes the first N launch attempts throw.
    static func harness(
        backend: RepositoryContractBackend,
        onboarded: Bool,
        contacts: (any ContactRepository)? = nil,
        reminders: (any ReminderRepository)? = nil,
        interactions: (any InteractionRepository)? = nil,
        makeRuntimeFailureCount: Int = 0,
        attempts: LaunchAttempts = LaunchAttempts(),
        gate: LaunchGate? = nil
    ) async throws -> Harness {
        let now = Self.now
        let backendRepositories = try backend.makeRepositories()
        let repositories = RepositoryContractRepositories(
            contacts: contacts ?? backendRepositories.contacts,
            groups: backendRepositories.groups,
            reminders: reminders ?? backendRepositories.reminders,
            interactions: interactions ?? backendRepositories.interactions,
            window: backendRepositories.window,
            profile: backendRepositories.profile
        )
        // Snooze reads the persisted window, not the runtime's copy.
        try await repositories.window.saveGlobal(ReminderWindow.defaultV1(timezone: windowZone))
        let environment = AppEnvironment(
            contacts: repositories.contacts,
            groups: repositories.groups,
            reminders: repositories.reminders,
            interactions: repositories.interactions,
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
            clock: { now },
            occasions: { _ in [] }
        )
        let fake = DebugNotificationScheduling()
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: {
                    await gate?.pause()
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
    static func seed(
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
        // The fixture's own UTC override would resolve every snooze through
        // 10:00-11:00 UTC; these tests use the global window.
        contact.reminderWindowOverride = nil
        try await harness.repositories.contacts.upsert(contact)
        return try #require(try await harness.repositories.contacts.fetch(id: contact.id))
    }

    /// A contact no action targeted still has no log, no snooze, and its
    /// original `lastInteractedAt`. A plain pending cadence row without a
    /// floor is allowed: the ready-phase run writes one for every overdue
    /// contact, and it is not an action's doing.
    ///
    /// `ineligible` contacts get no row from anything, the ready-phase run
    /// included, so for them any pending row at all is a failure.
    static func expectUntouched(_ harness: Harness, _ contact: Contact, ineligible: Bool = false) async throws {
        #expect(try await harness.repositories.interactions.fetchRecent(forContact: contact.id, limit: 10).isEmpty)
        let pending = try await harness.repositories.reminders.fetchPending(forContact: contact.id)
        #expect(ineligible ? pending.isEmpty : pending.allSatisfy { $0.snoozedUntil == nil })
        let after = try #require(try await harness.repositories.contacts.fetch(id: contact.id))
        #expect(after.lastInteractedAt == contact.lastInteractedAt)
    }

    /// Polls `condition` with `Task.yield()` between attempts, up to a fixed
    /// iteration count, instead of sleeping. A condition that throws counts as
    /// "not yet" (`try?`): a repository read can fail while a write is still
    /// in flight, and the final check after the loop decides the result.
    static func waitFor(_ condition: () async throws -> Bool) async -> Bool {
        for _ in 0..<3_000 {
            if (try? await condition()) == true { return true }
            await Task.yield()
        }
        return (try? await condition()) == true
    }

    /// The barrier action is a Snooze for `contactId`; once its pending row
    /// exists, every earlier action has been handled.
    static func expectBarrierSettled(_ harness: Harness, _ contactId: UUID) async {
        let settled = await waitFor {
            try await harness.scheduler.pendingSnoozeDate(contactId: contactId) != nil
        }
        #expect(settled, "the barrier action was never applied")
    }
}
