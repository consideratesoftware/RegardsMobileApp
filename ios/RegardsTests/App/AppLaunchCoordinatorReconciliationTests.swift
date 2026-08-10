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
        try await environment.contacts.upsert(existing)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "gone-x", givenName: "Going", familyName: "Away",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let launch = coordinator(environment: environment, source: source)

        await launch.start()

        #expect(launch.reconciliationCount == 1)
        let stillPresent = try await environment.contacts.fetch(id: existing.id)
        #expect(stillPresent?.archivedAt == nil)

        source.setContacts([])
        await launch.handleSceneActivation()

        #expect(launch.reconciliationCount == 2)
        let archived = try await environment.contacts.fetch(id: existing.id)
        #expect(archived?.archivedAt == now)
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
        try await environment.contacts.upsert(existing)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "gone-y", givenName: "Also", familyName: "Going",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let launch = coordinator(environment: environment, source: source)

        await launch.start()
        #expect(launch.reconciliationCount == 1)

        source.setContacts([])
        source.simulateChange()

        #expect(await eventually { launch.reconciliationCount == 2 })
        let archived = try await environment.contacts.fetch(id: existing.id)
        #expect(archived?.archivedAt == now)
    }

    private func coordinator(
        environment: AppEnvironment,
        source: any ContactsSource
    ) -> AppLaunchCoordinator {
        let now = self.now
        return AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: {
                    try await AppRuntime.makeProduction(environment: environment)
                },
                contactsSource: source,
                clock: { now }
            )
        )
    }
}

// `MutableContactsSource` lives in RegardsTests/Support — shared across the
// reconciler and launch-coordinator reconciliation suites.
