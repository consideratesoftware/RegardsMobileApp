import Foundation
import Testing
@testable import Regards

/// TF-03 / PR21 — reconciliation triggers owned by `AppLaunchCoordinator`:
/// launch (covered by `AppLaunchCoordinatorTests
/// .completedProfileOpensImmediatelyThenReconciles`), foreground, and
/// `CNContactStoreDidChange`. `reconciliationCount` is a test-only counter
/// so these tests can await a specific pass instead of sleeping.
@MainActor
struct AppLaunchCoordinatorReconciliationTests {
    let now = Date(timeIntervalSince1970: 1_785_600_000)

    @Test("Foregrounding re-reconciles Contacts and reflects a deletion")
    func foregroundReconciles() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let existing = Contact(
            systemContactRef: "gone-x",
            displayName: "Going Away",
            tracked: true
        )
        let staying = Contact(systemContactRef: "staying-x", displayName: "Staying")
        try await environment.contacts.upsert(existing)
        try await environment.contacts.upsert(staying)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "gone-x", givenName: "Going", familyName: "Away",
                          phoneNumbers: [], emailAddresses: []),
            SystemContact(identifier: "staying-x", givenName: "Staying", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let clock = MutableClock(now)
        let launch = coordinator(environment: environment, source: source, clock: clock.now)

        await launch.start()

        #expect(launch.reconciliationCount == 1)
        let stillPresent = try await environment.contacts.fetch(id: existing.id)
        #expect(stillPresent?.archivedAt == nil)

        source.setContacts([
            SystemContact(identifier: "staying-x", givenName: "Staying", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        // Round 9/10: a ref only archives once it's missing on two
        // consecutive `.authorized` passes at least `archiveDebounceFloor`
        // apart — `AppLaunchCoordinator` threads that state across calls
        // itself, so the first foreground after "gone-x" disappears just
        // records the miss.
        await launch.handleSceneActivation()
        #expect(launch.reconciliationCount == 2)
        let stillNotArchivedAfterFirstMiss = try await environment.contacts.fetch(id: existing.id)
        #expect(stillNotArchivedAfterFirstMiss?.archivedAt == nil)

        clock.advance(by: ContactsReconciler.archiveDebounceFloor)
        await launch.handleSceneActivation()

        #expect(launch.reconciliationCount == 3)
        let archived = try await environment.contacts.fetch(id: existing.id)
        #expect(archived?.archivedAt == clock.now())
    }

    @Test("Foregrounding before the runtime is ready is a no-op")
    func foregroundBeforeReadyIsNoOp() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = MutableContactsSource(status: .authorized, contacts: [])
        let launch = coordinator(environment: environment, source: source)

        // Never called `start()` — coordinator is still `.loading`.
        await launch.handleSceneActivation()

        #expect(launch.reconciliationCount == 0)
        #expect(source.fetchCountValue() == 0)
    }

    @Test("Foregrounding reconciles a rename and a re-appeared (un-archived) contact")
    func foregroundReconcilesRenameAndReappear() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let toRename = Contact(systemContactRef: "rename-1", displayName: "Old Name", tracked: true)
        let toReappear = Contact(
            systemContactRef: "reappear-1",
            displayName: "Reappeared",
            tracked: true,
            archivedAt: now.addingTimeInterval(-86_400)
        )
        try await environment.contacts.upsert(toRename)
        try await environment.contacts.upsert(toReappear)
        // "reappear-1" starts outside the visible set — it's already
        // archived, matching a contact currently outside a limited-access
        // grant or one the store legitimately doesn't expose yet.
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "rename-1", givenName: "Old", familyName: "Name",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let launch = coordinator(environment: environment, source: source)

        await launch.start()
        #expect(launch.reconciliationCount == 1)
        let stillArchived = try await environment.contacts.fetch(id: toReappear.id)
        #expect(stillArchived?.archivedAt != nil)

        // Rename "rename-1" and bring "reappear-1" into view for the next
        // foreground.
        source.setContacts([
            SystemContact(identifier: "rename-1", givenName: "New", familyName: "Name",
                          phoneNumbers: [], emailAddresses: []),
            SystemContact(identifier: "reappear-1", givenName: "Reappeared", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        await launch.handleSceneActivation()

        #expect(launch.reconciliationCount == 2)
        let renamed = try await environment.contacts.fetch(id: toRename.id)
        #expect(renamed?.displayName == "New Name")
        let reappeared = try await environment.contacts.fetch(id: toReappear.id)
        #expect(reappeared?.archivedAt == nil)
        #expect(reappeared?.tracked == true)
    }

    @Test("A .notDetermined foreground for a returning user is a clean no-op")
    func notDeterminedForegroundIsCleanNoOp() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let existing = Contact(systemContactRef: "untouched-1", displayName: "Untouched", tracked: true)
        try await environment.contacts.upsert(existing)
        let source = MutableContactsSource(status: .notDetermined, contacts: [])
        let launch = coordinator(environment: environment, source: source)

        await launch.start()
        #expect(launch.phase == .ready)
        // Reconciliation is attempted, throws `notAuthorized` internally,
        // and that failure is caught and logged rather than surfaced —
        // launch itself never blocks or fails on it.
        #expect(launch.reconciliationCount == 1)

        await launch.handleSceneActivation()
        #expect(launch.reconciliationCount == 2)

        let stillPresent = try await environment.contacts.fetch(id: existing.id)
        #expect(stillPresent?.archivedAt == nil)
        #expect(stillPresent?.displayName == "Untouched")
    }

    @Test("A CNContactStoreDidChange notification triggers reconciliation")
    func storeChangeNotificationReconciles() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let existing = Contact(
            systemContactRef: "gone-y",
            displayName: "Also Going",
            tracked: true
        )
        let staying = Contact(systemContactRef: "staying-y", displayName: "Staying")
        try await environment.contacts.upsert(existing)
        try await environment.contacts.upsert(staying)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "gone-y", givenName: "Also", familyName: "Going",
                          phoneNumbers: [], emailAddresses: []),
            SystemContact(identifier: "staying-y", givenName: "Staying", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let clock = MutableClock(now)
        let launch = coordinator(environment: environment, source: source, clock: clock.now)

        await launch.start()
        #expect(launch.reconciliationCount == 1)

        source.setContacts([
            SystemContact(identifier: "staying-y", givenName: "Staying", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        // Round 9/10: the first miss just records "gone-y" as newly missing
        // — archiving needs a second consecutive `.authorized` pass, at
        // least `archiveDebounceFloor` later, that still doesn't see it.
        source.simulateChange()
        #expect(await eventually { launch.reconciliationCount == 2 })
        let stillNotArchivedAfterFirstMiss = try await environment.contacts.fetch(id: existing.id)
        #expect(stillNotArchivedAfterFirstMiss?.archivedAt == nil)

        clock.advance(by: ContactsReconciler.archiveDebounceFloor)
        source.simulateChange()

        #expect(await eventually { launch.reconciliationCount == 3 })
        let archived = try await environment.contacts.fetch(id: existing.id)
        #expect(archived?.archivedAt == clock.now())
    }

    /// Fix 7: a store-change notification landing while the coordinator has
    /// no `runtime` yet (the `retry()` window this coordinator's own
    /// `launchFailureMessage`/`retry()` guards already model as `phase ==
    /// .ready && runtime == nil`, even though no call site drives it there
    /// today) must not be silently dropped. `beginObservingContactStoreChanges`
    /// is called directly here, before `start()`, because that's the only
    /// way to land a notification while `runtime` is still `nil` — it's the
    /// exact same call `start()` itself makes once a runtime exists, so this
    /// proves the replay mechanism directly rather than depending on
    /// call-site timing production doesn't yet exercise.
    @Test("A store-change notification arriving before a runtime exists is replayed once one does")
    func storeChangeBeforeRuntimeReplaysOnceRuntimeExists() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let source = MutableContactsSource(status: .authorized, contacts: [])
        let launch = coordinator(environment: environment, source: source)
        let dependencies = try #require(launch.dependencies)

        launch.beginObservingContactStoreChanges(dependencies: dependencies)
        source.simulateChange()
        #expect(await eventually { launch.pendingStoreChangeReplay })

        await launch.start()

        #expect(launch.phase == .ready)
        #expect(!launch.pendingStoreChangeReplay)
        // One pass for the replayed notification, one for `start()`'s own
        // unconditional launch reconcile — sequential, not coalesced
        // (`reconciliationTask` is nil again by the time the second one
        // starts), so this is two genuine passes, not one pass double-counted.
        #expect(launch.reconciliationCount == 2)
        #expect(launch.reconciliationCoalesceCount == 0)
    }

    // MARK: - Scheduling pass after a store change (TF-07e, §9 triggers)

    /// A contact archived while the app is open (an iCloud sync) must lose its
    /// pending row, and with it the OS notification, without waiting for a
    /// foreground. The second change is the confirming miss, `floor` after the
    /// first. The cancel is the only transition in this scenario, so its
    /// arrival at the gated repository proves the change's pass ran. The gate
    /// stays closed until then; if the pass never runs, the arrival never
    /// comes and the time limit ends the test.
    @Test(
        "A store change that archives a contact cancels its pending row without a foreground",
        .timeLimit(.minutes(1))
    )
    func storeChangeArchiveCancelsTheRowWithoutAForeground() async throws {
        let base = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let cancelSignal = AsyncGate()
        let environment = AppEnvironment(
            contacts: base.contacts,
            groups: base.groups,
            reminders: GatedTransitionStateReminderRepository(wrapped: base.reminders, gate: cancelSignal),
            interactions: base.interactions,
            window: base.window,
            profile: base.profile
        )
        try await environment.profile.save(onboardedProfile)
        // Talked yesterday on a 30-day cadence: the row's slot is weeks ahead,
        // so no run marks it fired and only the archive can remove it.
        let leaving = Contact(
            systemContactRef: "gone-s", displayName: "Leaving", tracked: true, cadenceDays: 30,
            lastInteractedAt: now.addingTimeInterval(-86_400), createdAt: now.addingTimeInterval(-90 * 86_400))
        try await environment.contacts.upsert(leaving)
        let staying = SystemContact(
            identifier: "staying-s", givenName: "Staying", familyName: "",
            phoneNumbers: [], emailAddresses: [])
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "gone-s", givenName: "Leaving", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
            staying,
        ])
        let clock = MutableClock(now)
        let launch = coordinator(environment: environment, source: source, clock: clock.now, schedulerClock: clock.now)

        await launch.start()
        #expect(launch.reconciliationCount == 1)
        #expect(try await environment.reminders.fetchPending(forContact: leaving.id).count == 1)

        source.setContacts([staying])
        source.simulateChange()
        #expect(await eventuallyPumpingRunLoop { launch.reconciliationCount == 2 })
        clock.advance(by: ContactsReconciler.archiveDebounceFloor)
        source.simulateChange()

        // The pass parks at its cancel; only the pass can bring it here.
        await cancelSignal.waitUntilArrived()
        await cancelSignal.open()
        // The pass holds the scheduler's lock from its read to its last write,
        // so this call returns only after that pass has finished.
        let scheduler = try #require(launch.runtime?.scheduler)
        try await scheduler.run(for: UUID())
        #expect(await cancelSignal.arrivalCount == 1, "the store change's pass made one transition: the cancel")
        let archived = try await environment.contacts.fetch(id: leaving.id)
        #expect(archived?.archivedAt == clock.now())
        #expect(try await environment.reminders.fetchPending(forContact: leaving.id).isEmpty)
    }

    /// The replay in `start()` is followed by the `.ready` launch pass, so a
    /// change that arrived with no runtime still cancels the archived
    /// contact's row before `start()` returns. Pins the order: reconcile, then
    /// pass. The miss is seeded 6 minutes back, past the debounce floor, so
    /// the replayed reconcile is the confirming one.
    @Test("A replayed store change is followed by a scheduling pass before start returns")
    func replayedStoreChangeIsFollowedByAPass() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(onboardedProfile)
        let leaving = Contact(
            systemContactRef: "gone-r", displayName: "Leaving", tracked: true, cadenceDays: 30,
            lastInteractedAt: now.addingTimeInterval(-86_400), createdAt: now.addingTimeInterval(-90 * 86_400))
        try await environment.contacts.upsert(leaving)
        try await environment.reminders.upsert(ScheduledReminder(
            contactId: leaving.id,
            kind: .cadence,
            scheduledFor: now.addingTimeInterval(29 * 86_400),
            osNotificationId: "contact-\(leaving.id.uuidString)-cadence"))
        let store = MissingContactRefStore.ephemeral()
        try store.save([ContactRefHasher.hash("gone-r"): now.addingTimeInterval(-6 * 60)])
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "staying-r", givenName: "Staying", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let clock = MutableClock(now)
        let launch = coordinator(
            environment: environment, source: source, clock: clock.now,
            schedulerClock: clock.now, missingContactRefStore: store)
        let dependencies = try #require(launch.dependencies)
        launch.beginObservingContactStoreChanges(dependencies: dependencies)
        source.simulateChange()
        #expect(await eventually { launch.pendingStoreChangeReplay })
        #expect(try await environment.reminders.fetchPending(forContact: leaving.id).count == 1)

        await launch.start()

        #expect(launch.reconciliationCount == 2)
        let archived = try await environment.contacts.fetch(id: leaving.id)
        #expect(archived?.archivedAt != nil)
        #expect(try await environment.reminders.fetchPending(forContact: leaving.id).isEmpty)
    }

    private var onboardedProfile: UserProfile {
        UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        )
    }

    func coordinator(
        environment: AppEnvironment,
        source: any ContactsSource,
        clock: (@Sendable () -> Date)? = nil,
        schedulerClock: (@Sendable () -> Date)? = nil,
        missingContactRefStore: MissingContactRefStore = .ephemeral()
    ) -> AppLaunchCoordinator {
        let now = self.now
        return AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: {
                    // Scheduling tests need the pass on the test's clock;
                    // `makeProduction` reads the wall clock.
                    guard let schedulerClock else {
                        return try await AppRuntime.makeProduction(environment: environment)
                    }
                    return AppRuntime(
                        environment: environment,
                        window: try await environment.window.fetchGlobal(),
                        userCalendar: Calendar(identifier: .gregorian),
                        clock: schedulerClock,
                        occasions: { _ in [] }
                    )
                },
                contactsSource: source,
                clock: clock ?? { now },
                missingContactRefStore: missingContactRefStore
            )
        )
    }
}

// `MutableContactsSource` lives in RegardsTests/Support — shared across the
// reconciler and launch-coordinator reconciliation suites.
