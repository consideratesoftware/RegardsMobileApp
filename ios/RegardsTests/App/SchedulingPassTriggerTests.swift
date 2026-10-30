import Foundation
import Testing
@testable import Regards

/// Where the pass runs (TF-07c, §9a "Triggers"): the `.ready` phase on launch
/// and retry, foreground, a global window save, and a contact override save.
/// Built on `NotificationActionHandlingTests`' coordinator harness: a
/// fixed clock of Wed 2027-03-10 10:00 in Los Angeles and the default
/// weekday window (12:00-13:00 and 18:00-22:00), so a contact who is long
/// overdue gets a cadence row at 12:00 that day.
@MainActor
struct SchedulingPassTriggerTests {
    typealias Harness = NotificationActionHandlingTests.Harness

    private static func la(_ local: String) -> Date {
        EngineFixtures.date(local, tz: "America/Los_Angeles")
    }

    private static func cadenceRow(_ harness: Harness, _ contact: Contact) async throws -> ScheduledReminder? {
        try await harness.repositories.reminders.fetchPending(forContact: contact.id).first { $0.kind == .cadence }
    }

    private static let overdueSlot = "2027-03-10 12:00"

    // MARK: - Launch, retry and foreground

    @Test("Reaching .ready on launch runs the pass", arguments: RepositoryContractBackend.allCases)
    func launchRunsThePass(backend: RepositoryContractBackend) async throws {
        let harness = try await NotificationActionHandlingTests.harness(backend: backend, onboarded: true)
        let contact = try await NotificationActionHandlingTests.seed(harness, id: 701, suffix: "trigger-launch")

        await harness.launch.start()

        #expect(harness.launch.phase == .ready)
        #expect(try await Self.cadenceRow(harness, contact)?.scheduledFor == Self.la(Self.overdueSlot))
    }

    @Test(
        "Reaching .ready through Try Again after a failed launch runs the pass",
        arguments: RepositoryContractBackend.allCases
    )
    func retryRunsThePass(backend: RepositoryContractBackend) async throws {
        let harness = try await NotificationActionHandlingTests.harness(
            backend: backend, onboarded: true, makeRuntimeFailureCount: 1)
        let contact = try await NotificationActionHandlingTests.seed(harness, id: 702, suffix: "trigger-retry")
        await harness.launch.start()
        #expect(harness.launch.phase == .failed)
        #expect(try await Self.cadenceRow(harness, contact) == nil)

        await harness.launch.retry()

        #expect(harness.launch.phase == .ready)
        #expect(try await Self.cadenceRow(harness, contact)?.scheduledFor == Self.la(Self.overdueSlot))
    }

    @Test("Foregrounding the app runs the pass", arguments: RepositoryContractBackend.allCases)
    func foregroundRunsThePass(backend: RepositoryContractBackend) async throws {
        let harness = try await NotificationActionHandlingTests.readyHarness(backend: backend)
        let contact = try await NotificationActionHandlingTests.seed(harness, id: 703, suffix: "trigger-foreground")
        #expect(try await Self.cadenceRow(harness, contact) == nil)

        await harness.launch.handleSceneActivation()

        #expect(try await Self.cadenceRow(harness, contact)?.scheduledFor == Self.la(Self.overdueSlot))
    }

    // MARK: - Window saves

    /// Saving the global window reschedules every contact through the
    /// runtime's one pass: no second `SchedulingPass` or `AppRuntime` is
    /// built (R55), so the lock still serialises every caller.
    @Test(
        "A global window save reschedules through the same scheduler instance",
        arguments: RepositoryContractBackend.allCases
    )
    func globalSaveRunsThePassOnTheSameScheduler(backend: RepositoryContractBackend) async throws {
        let harness = try await NotificationActionHandlingTests.harness(backend: backend, onboarded: true)
        let contact = try await NotificationActionHandlingTests.seed(harness, id: 704, suffix: "trigger-global")
        await harness.launch.start()
        let runtime = try #require(harness.launch.runtime)
        let schedulerBefore = runtime.scheduler
        let upcoming = RegardsTabRoot.makeUpcomingViewModel(runtime: runtime)
        let editor = RegardsTabRoot.makeReminderWindowsViewModel(runtime: runtime, upcoming: upcoming)
        await editor.load()
        #expect(try await Self.cadenceRow(harness, contact)?.scheduledFor == Self.la(Self.overdueSlot))
        editor.draft.allowedTimeRanges = [TimeRange(start: TimeOfDay(hour: 14), end: TimeOfDay(hour: 15))]

        let saved = await editor.save()

        #expect(saved)
        #expect(try await Self.cadenceRow(harness, contact)?.scheduledFor == Self.la("2027-03-10 14:00"))
        #expect(harness.launch.runtime?.scheduler === schedulerBefore)
    }

    /// An override save runs only that contact. Another contact's stale row
    /// stays as it was until a full run.
    @Test("A contact override save reschedules that contact only", arguments: RepositoryContractBackend.allCases)
    func overrideSaveRunsOnlyThatContact(backend: RepositoryContractBackend) async throws {
        let harness = try await NotificationActionHandlingTests.harness(backend: backend, onboarded: true)
        let edited = try await NotificationActionHandlingTests.seed(harness, id: 705, suffix: "trigger-override")
        let bystander = try await NotificationActionHandlingTests.seed(harness, id: 706, suffix: "trigger-bystander")
        await harness.launch.start()
        let runtime = try #require(harness.launch.runtime)
        let staleRow = ScheduledReminder(
            id: SchedulingPass.reminderID(contactId: bystander.id, kind: .cadence),
            contactId: bystander.id,
            kind: .cadence,
            scheduledFor: Self.la("2027-03-30 12:00"),
            osNotificationId: "contact-\(bystander.id.uuidString)-cadence")
        try await harness.repositories.reminders.upsert(staleRow)
        let editor = RegardsTabRoot.makeContactWindowEditor(contactId: edited.id, runtime: runtime)
        await editor.load()
        editor.draft.allowedTimeRanges = [TimeRange(start: TimeOfDay(hour: 14), end: TimeOfDay(hour: 15))]

        let saved = await editor.save()

        #expect(saved)
        #expect(try await Self.cadenceRow(harness, edited)?.scheduledFor == Self.la("2027-03-10 14:00"))
        #expect(try await Self.cadenceRow(harness, bystander) == staleRow)
    }

    /// "Use default window" clears the override and re-runs that contact, so
    /// its row returns to the global window's slot.
    @Test(
        "Resetting a contact override to the default window reschedules that contact",
        arguments: RepositoryContractBackend.allCases
    )
    func overrideResetRunsThatContact(backend: RepositoryContractBackend) async throws {
        let harness = try await NotificationActionHandlingTests.harness(backend: backend, onboarded: true)
        let contact = try await NotificationActionHandlingTests.seed(harness, id: 707, suffix: "trigger-reset")
        let afternoon = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 14), end: TimeOfDay(hour: 15))],
            timezoneIdentifier: "America/Los_Angeles")
        _ = try await harness.repositories.contacts.updateReminderWindowOverride(id: contact.id, window: afternoon)
        await harness.launch.start()
        let runtime = try #require(harness.launch.runtime)
        #expect(try await Self.cadenceRow(harness, contact)?.scheduledFor == Self.la("2027-03-10 14:00"))
        let editor = RegardsTabRoot.makeContactWindowEditor(contactId: contact.id, runtime: runtime)
        await editor.load()

        let reset = await editor.resetToDefault()

        #expect(reset)
        #expect(try await Self.cadenceRow(harness, contact)?.scheduledFor == Self.la(Self.overdueSlot))
    }

    // MARK: - Failure

    /// The pass logs its failure and the app carries on (§9a): a read failure
    /// must not hold the tab root back, on launch or on foreground.
    @Test("A failing pass does not keep the app out of .ready")
    func passFailureDoesNotBlockReady() async throws {
        // `StubReminderRepository.observeSchedule()` finishes with no value,
        // which makes `runFull()` throw.
        let harness = try await NotificationActionHandlingTests.harness(
            backend: .mock, onboarded: true, reminders: StubReminderRepository())
        await #expect(throws: (any Error).self) { try await harness.scheduler.runFull() }

        await harness.launch.start()
        #expect(harness.launch.phase == .ready)

        await harness.launch.handleSceneActivation()

        #expect(harness.launch.phase == .ready)
    }

    // MARK: - A failing pass after a window save

    /// `StubReminderRepository.observeSchedule()` finishes with no value, so
    /// `runFull()` and `run(for:)` throw while every write still lands.
    private static func failingPassHarness() async throws -> Harness {
        let harness = try await NotificationActionHandlingTests.harness(
            backend: .mock, onboarded: true, reminders: StubReminderRepository())
        await harness.launch.start()
        return harness
    }

    private static let afternoon = [TimeRange(start: TimeOfDay(hour: 14), end: TimeOfDay(hour: 15))]
    private static let notRescheduled = ReminderWindowsViewModel.notRescheduledMessage

    @Test("A global save whose pass fails tells the editor, and Upcoming still gets the window")
    func globalSaveWithFailingPassSaysRemindersDidNotUpdate() async throws {
        let harness = try await Self.failingPassHarness()
        let runtime = try #require(harness.launch.runtime)
        let upcoming = RegardsTabRoot.makeUpcomingViewModel(runtime: runtime)
        let editor = RegardsTabRoot.makeReminderWindowsViewModel(runtime: runtime, upcoming: upcoming)
        await editor.load()
        editor.draft.allowedTimeRanges = Self.afternoon

        let saved = await editor.save()

        #expect(!saved)
        #expect(editor.validationMessage == Self.notRescheduled)
        let stored = try await runtime.environment.window.fetchGlobal()
        #expect(stored.allowedTimeRanges == Self.afternoon)
        #expect(upcoming.window == stored)
    }

    @Test("An override save whose pass fails tells the editor, with the override stored")
    func overrideSaveWithFailingPassSaysRemindersDidNotUpdate() async throws {
        let harness = try await Self.failingPassHarness()
        let runtime = try #require(harness.launch.runtime)
        let contact = try await NotificationActionHandlingTests.seed(harness, id: 708, suffix: "failing-override")
        let editor = RegardsTabRoot.makeContactWindowEditor(contactId: contact.id, runtime: runtime)
        await editor.load()
        editor.draft.allowedTimeRanges = Self.afternoon

        let saved = await editor.save()

        #expect(!saved)
        #expect(editor.validationMessage == Self.notRescheduled)
        let stored = try await harness.repositories.contacts.fetch(id: contact.id)
        #expect(stored?.reminderWindowOverride?.allowedTimeRanges == Self.afternoon)
    }

    @Test("An override reset whose pass fails tells the editor, with the override cleared")
    func overrideResetWithFailingPassSaysRemindersDidNotUpdate() async throws {
        let harness = try await Self.failingPassHarness()
        let runtime = try #require(harness.launch.runtime)
        let contact = try await NotificationActionHandlingTests.seed(harness, id: 709, suffix: "failing-reset")
        let override = ReminderWindow(
            allowedDays: .allDays, allowedTimeRanges: Self.afternoon, timezoneIdentifier: "America/Los_Angeles")
        _ = try await harness.repositories.contacts.updateReminderWindowOverride(id: contact.id, window: override)
        let editor = RegardsTabRoot.makeContactWindowEditor(contactId: contact.id, runtime: runtime)
        await editor.load()

        let reset = await editor.resetToDefault()

        #expect(!reset)
        #expect(editor.validationMessage == Self.notRescheduled)
        #expect(try await harness.repositories.contacts.fetch(id: contact.id)?.reminderWindowOverride == nil)
    }
}
