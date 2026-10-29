import Foundation
import Testing
@testable import Regards

/// The triggers that need their order or their wiring pinned (TF-07c, §9
/// "App launch/foreground"): the pass runs after the Contacts reconcile on
/// launch and foreground, when onboarding finishes, and when a contact's
/// override is reset. A reconcile reaches the pass through an archived
/// contact the system store still exposes: the reconcile un-archives it, so a
/// pass that ran before the reconcile would not schedule it.
///
/// The production runtime uses the real clock, so these tests assert that a
/// long-overdue contact has a cadence row, not when it fires.
@MainActor
struct SchedulingPassTriggerOrderTests {
    private let now = Date(timeIntervalSince1970: 1_785_600_000)

    private static let systemContact = SystemContact(
        identifier: "order-contact", givenName: "Order", familyName: "Test",
        phoneNumbers: [], emailAddresses: [])

    private static func environment(onboarded: Bool, now: Date) async throws -> AppEnvironment {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        if onboarded {
            try await environment.profile.save(UserProfile(
                onboardingCompletedAt: now, entitlementTier: .trial,
                entitlementRefreshedAt: now, trialStartedAt: now))
        }
        return environment
    }

    private static func overdueContact(archivedAt: Date? = nil) -> Contact {
        Contact(
            systemContactRef: systemContact.identifier,
            displayName: "Order Test",
            tracked: true,
            cadenceDays: 7,
            lastInteractedAt: Date(timeIntervalSince1970: 1_600_000_000),
            archivedAt: archivedAt)
    }

    private func coordinator(environment: AppEnvironment, source: any ContactsSource) -> AppLaunchCoordinator {
        let now = self.now
        return AppLaunchCoordinator(dependencies: .init(
            makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
            contactsSource: source,
            clock: { now }))
    }

    private static func hasCadenceRow(_ environment: AppEnvironment, _ contact: Contact) async throws -> Bool {
        try await environment.reminders.fetchPending(forContact: contact.id).contains { $0.kind == .cadence }
    }

    @Test("Launch runs the pass after the Contacts reconcile, so a contact the reconcile un-archives is scheduled")
    func launchRunsThePassAfterTheReconcile() async throws {
        let environment = try await Self.environment(onboarded: true, now: now)
        let contact = Self.overdueContact(archivedAt: now.addingTimeInterval(-86_400))
        try await environment.contacts.upsert(contact)
        let source = MutableContactsSource(status: .authorized, contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)

        await launch.start()

        #expect(try await environment.contacts.fetch(id: contact.id)?.archivedAt == nil)
        #expect(try await Self.hasCadenceRow(environment, contact))
    }

    @Test("Foreground runs the pass after the Contacts reconcile, so a contact the reconcile un-archives is scheduled")
    func foregroundRunsThePassAfterTheReconcile() async throws {
        let environment = try await Self.environment(onboarded: true, now: now)
        let contact = Self.overdueContact(archivedAt: now.addingTimeInterval(-86_400))
        try await environment.contacts.upsert(contact)
        // Denied at launch: no reconcile, so the contact stays archived.
        let source = MutableContactsSource(status: .denied, contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        #expect(try await Self.hasCadenceRow(environment, contact) == false)

        source.setStatus(.authorized)
        await launch.handleSceneActivation()

        #expect(try await environment.contacts.fetch(id: contact.id)?.archivedAt == nil)
        #expect(try await Self.hasCadenceRow(environment, contact))
    }

    @Test("Finishing onboarding without contacts runs the pass")
    func onboardingWithoutContactsRunsThePass() async throws {
        let environment = try await Self.environment(onboarded: false, now: now)
        let contact = Self.overdueContact()
        try await environment.contacts.upsert(contact)
        let launch = coordinator(environment: environment, source: ScriptedLaunchContactsSource(status: .denied))
        await launch.start()
        #expect(launch.phase == .onboarding)
        #expect(try await Self.hasCadenceRow(environment, contact) == false)

        await launch.continueWithoutContacts()

        #expect(launch.phase == .ready)
        #expect(try await Self.hasCadenceRow(environment, contact))
    }

    @Test("Finishing onboarding after the import runs the pass")
    func onboardingAfterImportRunsThePass() async throws {
        let environment = try await Self.environment(onboarded: false, now: now)
        let contact = Self.overdueContact()
        try await environment.contacts.upsert(contact)
        let source = ScriptedLaunchContactsSource(
            status: .notDetermined, contacts: [Self.systemContact], requestResult: .authorized)
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        #expect(try await Self.hasCadenceRow(environment, contact) == false)

        await launch.requestContactsAndImport()

        #expect(launch.phase == .ready)
        #expect(try await Self.hasCadenceRow(environment, contact))
    }

    /// The production composition has no occasion source until PR30. A
    /// contact that the mock provider would give a birthday gets none.
    @Test("The production runtime writes no occasion rows")
    func productionRuntimeWritesNoOccasionRows() async throws {
        let environment = try await Self.environment(onboarded: true, now: now)
        let shmi = Contact(
            systemContactRef: "sys-shmi", displayName: "Shmi", tracked: true, cadenceDays: 7,
            lastInteractedAt: Date(timeIntervalSince1970: 1_600_000_000))
        let obiWan = Contact(
            systemContactRef: "sys-obiwan", displayName: "Obi-Wan", tracked: true, cadenceDays: 7,
            lastInteractedAt: Date(timeIntervalSince1970: 1_600_000_000))
        try await environment.contacts.upsert(shmi)
        try await environment.contacts.upsert(obiWan)
        let runtime = try await AppRuntime.makeProduction(environment: environment)

        try await runtime.scheduler.runFull()

        let pending = try await environment.reminders.fetchAllPending()
        #expect(pending.contains { $0.kind == .cadence }, "the run did schedule")
        #expect(pending.filter { $0.kind != .cadence }.isEmpty)
    }
}
