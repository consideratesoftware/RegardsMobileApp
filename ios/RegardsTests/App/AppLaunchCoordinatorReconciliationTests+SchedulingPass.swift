import Foundation
import Testing
@testable import Regards

/// The scheduling pass after a Contacts store change (TF-07e, §9 triggers),
/// in an extension only to keep `AppLaunchCoordinatorReconciliationTests`
/// under `type_body_length`. Shares its `coordinator(...)` harness.
extension AppLaunchCoordinatorReconciliationTests {

    /// A change that lands while the coordinator has a runtime but is not
    /// `.ready` (here onboarding, in production a `retry()`) reconciles
    /// Contacts and nothing more; onboarding's completion runs its own pass.
    /// The due pending row is what a pass would touch: it would mark it fired.
    /// The observer takes one change at a time, so the second reconcile starts
    /// only after the first change's pass, had there been one, has finished.
    @Test("A store change before the app is ready reconciles Contacts without running the pass")
    func storeChangeBeforeReadyDoesNotRunThePass() async throws {
        let base = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let reminders = CountingReminderRepository(base.reminders)
        let environment = AppEnvironment(
            contacts: base.contacts,
            groups: base.groups,
            reminders: reminders,
            interactions: base.interactions,
            window: base.window,
            profile: base.profile
        )
        // Onboarding is not complete, so `start()` stops there with a runtime.
        try await environment.profile.save(UserProfile(
            entitlementTier: .trial, entitlementRefreshedAt: now, trialStartedAt: now))
        let due = Contact(
            systemContactRef: "due-b", displayName: "Due", tracked: true, cadenceDays: 7,
            lastInteractedAt: now.addingTimeInterval(-86_400), createdAt: now.addingTimeInterval(-90 * 86_400))
        try await environment.contacts.upsert(due)
        let dueRow = ScheduledReminder(
            id: SchedulingPass.reminderID(contactId: due.id, kind: .cadence),
            contactId: due.id,
            kind: .cadence,
            scheduledFor: now.addingTimeInterval(-3_600),
            osNotificationId: "contact-\(due.id.uuidString)-cadence")
        try await environment.reminders.upsert(dueRow)
        let source = MutableContactsSource(status: .notDetermined, contacts: [])
        let clock = MutableClock(now)
        let launch = coordinator(environment: environment, source: source, clock: clock.now, schedulerClock: clock.now)

        await launch.start()
        #expect(launch.phase == .onboarding)
        #expect(launch.runtime != nil)
        launch.beginObservingContactStoreChanges(dependencies: try #require(launch.dependencies))
        source.simulateChange()
        #expect(await eventuallyPumpingRunLoop { launch.reconciliationCount == 1 })
        source.simulateChange()
        #expect(await eventuallyPumpingRunLoop { launch.reconciliationCount == 2 })

        #expect(await reminders.transitions == 0)
        #expect(try await environment.reminders.fetchPending(forContact: due.id) == [dueRow])
    }
}
