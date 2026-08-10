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
        let source = ControllableReconciliationContactsSource(contacts: [
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
        let source = ControllableReconciliationContactsSource(contacts: [])
        let launch = coordinator(environment: environment, source: source)

        // Never called `start()` — coordinator is still `.loading`.
        await launch.handleSceneActivation()

        #expect(launch.reconciliationCount == 0)
        #expect(source.fetchCountValue() == 0)
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
        let source = ControllableReconciliationContactsSource(contacts: [
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

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

/// A `ContactsSource` whose visible contact list and `changeNotifications()`
/// stream a test can drive explicitly, to prove foreground and
/// store-change reconciliation triggers independently of launch.
private final class ControllableReconciliationContactsSource: ContactsSource, @unchecked Sendable {
    private let lock = NSLock()
    private var contacts: [SystemContact]
    private var fetchCount = 0
    private var continuation: AsyncStream<Void>.Continuation?

    init(contacts: [SystemContact]) {
        self.contacts = contacts
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus { .authorized }
    func requestAccess() async throws -> ContactsAuthorizationStatus { .authorized }

    func fetchAllContacts() async throws -> [SystemContact] {
        lock.withLock {
            fetchCount += 1
            return contacts
        }
    }

    func setContacts(_ newContacts: [SystemContact]) {
        lock.withLock { contacts = newContacts }
    }

    func fetchCountValue() -> Int {
        lock.withLock { fetchCount }
    }

    func changeNotifications() -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func simulateChange() {
        lock.withLock { continuation }?.yield()
    }
}
