import Foundation
import GRDB
import Testing
@testable import Regards

@MainActor
struct AppLaunchCoordinatorTests {
    let now = Date(timeIntervalSince1970: 1_785_600_000)

    @Test("Completed onboarding opens the production runtime without Contacts access")
    func completedProfileBypassesContacts() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let environment = AppEnvironment.makeProduction(database: database)
        try await environment.profile.save(
            UserProfile(
                onboardingCompletedAt: now,
                entitlementTier: .trial,
                entitlementRefreshedAt: now,
                trialStartedAt: now
            )
        )
        let source = ScriptedLaunchContactsSource(status: .denied)
        let launch = coordinator(database: database, source: source)

        await launch.start()

        #expect(launch.phase == .ready)
        #expect(launch.runtime != nil)
        #expect(await source.counts() == .init(current: 0, requests: 0, fetches: 0))
    }

    @Test("Fresh launch records the trial and waits for the permission CTA")
    func freshLaunchWaitsForPermission() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let source = ScriptedLaunchContactsSource(status: .notDetermined)
        let launch = coordinator(database: database, source: source)

        await launch.start()

        #expect(launch.phase == .onboarding)
        let profile = try await launch.runtime?.environment.profile.fetch()
        #expect(profile?.trialStartedAt == now)
        #expect(profile?.entitlementTier == .trial)
        #expect(profile?.onboardingCompletedAt == nil)
        #expect(await source.counts() == .init(current: 1, requests: 0, fetches: 0))
    }

    @Test("An existing trial timestamp and entitlement are preserved")
    func existingTrialTimestampIsNotRestarted() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let environment = AppEnvironment.makeProduction(database: database)
        let originalTrialStart = now.addingTimeInterval(-86_400)
        let originalRefresh = now.addingTimeInterval(-43_200)
        try await environment.profile.save(
            UserProfile(
                entitlementTier: .trial,
                entitlementRefreshedAt: originalRefresh,
                trialStartedAt: originalTrialStart
            )
        )
        let source = ScriptedLaunchContactsSource(status: .notDetermined)
        let launch = coordinator(database: database, source: source)

        await launch.start()

        let profile = try await environment.profile.fetch()
        #expect(profile.trialStartedAt == originalTrialStart)
        #expect(profile.entitlementTier == .trial)
        #expect(profile.entitlementRefreshedAt == originalRefresh)
    }

    @Test("Recording a missing trial timestamp does not downgrade lifetime access")
    func lifetimeEntitlementIsNotDowngraded() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let environment = AppEnvironment.makeProduction(database: database)
        let originalRefresh = now.addingTimeInterval(-43_200)
        try await environment.profile.save(
            UserProfile(
                entitlementTier: .lifetime,
                entitlementRefreshedAt: originalRefresh
            )
        )
        let source = ScriptedLaunchContactsSource(status: .notDetermined)
        let launch = coordinator(database: database, source: source)

        await launch.start()

        let profile = try await environment.profile.fetch()
        #expect(profile.trialStartedAt == now)
        #expect(profile.entitlementTier == .lifetime)
        #expect(profile.entitlementRefreshedAt == originalRefresh)
    }

    @Test("An authorized relaunch resumes import and saves completion last")
    func authorizedRelaunchResumesImport() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let source = ScriptedLaunchContactsSource(
            status: .authorized,
            contacts: [Self.systemContact]
        )
        let launch = coordinator(database: database, source: source)

        await launch.start()

        #expect(launch.phase == .ready)
        let runtime = try #require(launch.runtime)
        let profile = try await runtime.environment.profile.fetch()
        #expect(profile.onboardingCompletedAt == now)
        #expect(try await runtime.environment.contacts.fetchAll().map(\.systemContactRef)
            == [Self.systemContact.identifier])
        #expect(await source.counts() == .init(current: 2, requests: 0, fetches: 1))
    }

    @Test("A failed import leaves onboarding incomplete and retry resumes")
    func failedImportCanRetry() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let source = ScriptedLaunchContactsSource(
            status: .notDetermined,
            contacts: [Self.systemContact],
            fetchFailuresRemaining: 1
        )
        let launch = coordinator(database: database, source: source)
        await launch.start()

        await launch.requestContactsAndImport()

        #expect(launch.phase == .onboarding)
        #expect(launch.statusMessage != nil)
        #expect(launch.canContinueWithoutContacts)
        #expect(!launch.isImporting)
        let runtimeAfterFailure = try #require(launch.runtime)
        #expect(try await runtimeAfterFailure.environment.profile.fetch().onboardingCompletedAt == nil)

        await launch.requestContactsAndImport()

        #expect(launch.phase == .ready)
        let runtime = try #require(launch.runtime)
        #expect(try await runtime.environment.contacts.fetchAll().count == 1)
        #expect(try await runtime.environment.profile.fetch().onboardingCompletedAt == now)
    }

    @Test("Denied permission offers a durable browse-only path")
    func deniedPermissionCanContinue() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let source = ScriptedLaunchContactsSource(status: .denied)
        let launch = coordinator(database: database, source: source)

        await launch.start()

        #expect(launch.phase == .onboarding)
        #expect(launch.canContinueWithoutContacts)
        await launch.continueWithoutContacts()
        #expect(launch.phase == .ready)
        let runtime = try #require(launch.runtime)
        #expect(try await runtime.environment.profile.fetch().onboardingCompletedAt == now)
        #expect(await source.counts().fetches == 0)
    }

    @Test("Permission-prompt denial offers the browse-only path")
    func permissionPromptDenialOffersBrowseWithoutContacts() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let source = ScriptedLaunchContactsSource(
            status: .notDetermined,
            requestResult: .denied
        )
        let launch = coordinator(database: database, source: source)

        await launch.start()
        await launch.requestContactsAndImport()

        #expect(launch.phase == .onboarding)
        #expect(launch.canContinueWithoutContacts)
        #expect(await source.counts() == .init(current: 1, requests: 1, fetches: 0))
        let runtimeBeforeBrowse = try #require(launch.runtime)
        #expect(try await runtimeBeforeBrowse.environment.profile.fetch().onboardingCompletedAt == nil)

        await launch.continueWithoutContacts()

        #expect(launch.phase == .ready)
        #expect(try await runtimeBeforeBrowse.environment.profile.fetch().onboardingCompletedAt == now)
    }

    @Test("A transient production-open failure retries into onboarding")
    func transientProductionOpenFailureRetriesToOnboarding() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let runtimeFactory = TransientRuntimeFactory(database: database)
        let source = ScriptedLaunchContactsSource(status: .notDetermined)
        let now = self.now
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await runtimeFactory.makeRuntime() },
                contactsSource: source,
                clock: { now }
            )
        )

        await launch.start()

        #expect(launch.phase == .failed)
        #expect(launch.statusMessage != nil)
        await launch.retry()
        #expect(launch.phase == .onboarding)
        #expect(launch.runtime != nil)
        #expect(launch.statusMessage == nil)
        #expect(await runtimeFactory.attemptCount() == 2)
    }

    @Test("A corrupt persisted window reaches visible launch recovery")
    func corruptPersistedWindowFailsLaunchRetryably() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        try await database.write { db in
            try db.execute(
                sql: "UPDATE ReminderWindow SET occasionTime = ? WHERE id = 1",
                arguments: ["24:00"]
            )
        }
        let source = ScriptedLaunchContactsSource(status: .notDetermined)
        let launch = coordinator(database: database, source: source)

        await launch.start()

        #expect(launch.phase == .failed)
        #expect(launch.runtime == nil)
        #expect(launch.statusMessage != nil)
        #expect(await source.counts() == .init(current: 0, requests: 0, fetches: 0))
    }

    @Test("A permission tap racing launch starts one import")
    func permissionTapRacingAuthorizationStartsOneImport() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let source = BlockingAuthorizationContactsSource(contacts: [Self.systemContact])
        let launch = coordinator(database: database, source: source)
        let start = Task { await launch.start() }
        await source.waitUntilCurrentAuthorizationStarts()
        await launch.requestContactsAndImport()
        await source.finishCurrentAuthorization()
        await start.value
        #expect(launch.phase == .ready)
        #expect(launch.statusMessage == nil)
        #expect(await source.counts() == .init(current: 2, requests: 1, fetches: 1))
        let runtime = try #require(launch.runtime)
        #expect(try await runtime.environment.profile.fetch().onboardingCompletedAt == now)
        #expect(try await runtime.environment.contacts.fetchAll().count == 1)
    }

    @Test("A completed permission action survives stale launch cancellation")
    func permissionActionWinsBeforeLaunchCancellation() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let source = BlockingAuthorizationContactsSource(contacts: [Self.systemContact])
        let launch = coordinator(database: database, source: source)
        let start = Task { await launch.start() }
        await source.waitUntilCurrentAuthorizationStarts()

        await launch.requestContactsAndImport()
        start.cancel()
        await source.finishCurrentAuthorization()
        await start.value

        #expect(launch.phase == .ready)
        #expect(launch.statusMessage == nil)
        let runtime = try #require(launch.runtime)
        #expect(try await runtime.environment.profile.fetch().onboardingCompletedAt == now)
        #expect(try await runtime.environment.contacts.fetchAll().count == 1)
    }

    @Test("A failed permission-tap import is not replaced by stale launch work")
    func failedPermissionTapRacingAuthorizationPreservesFailure() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let source = BlockingAuthorizationContactsSource(
            contacts: [Self.systemContact],
            fetchFailuresRemaining: 1
        )
        let launch = coordinator(database: database, source: source)
        let start = Task { await launch.start() }
        await source.waitUntilCurrentAuthorizationStarts()
        await launch.requestContactsAndImport()
        await source.finishCurrentAuthorization()
        await start.value
        #expect(launch.phase == .onboarding)
        #expect(launch.statusMessage != nil)
        #expect(await source.counts() == .init(current: 2, requests: 1, fetches: 1))
        let runtime = try #require(launch.runtime)
        #expect(try await runtime.environment.profile.fetch().onboardingCompletedAt == nil)
        #expect(try await runtime.environment.contacts.fetchAll().isEmpty)
    }

    @Test("Overlapping production-open retries start only one runtime attempt")
    func overlappingProductionOpenRetriesStartOneAttempt() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let runtimeFactory = BlockingRetryRuntimeFactory(database: database)
        let source = ScriptedLaunchContactsSource(status: .notDetermined)
        let now = self.now
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await runtimeFactory.makeRuntime() },
                contactsSource: source,
                clock: { now }
            )
        )

        await launch.start()
        #expect(launch.phase == .failed)

        let firstRetry = Task { await launch.retry() }
        await runtimeFactory.waitUntilRetryStarts()
        let overlappingRetry = Task { await launch.retry() }
        await overlappingRetry.value

        #expect(launch.phase == .loading)
        #expect(await runtimeFactory.attemptCount() == 2)

        await runtimeFactory.finishRetry()
        await firstRetry.value

        #expect(launch.phase == .onboarding)
        #expect(launch.runtime != nil)
        #expect(await runtimeFactory.attemptCount() == 2)
    }

    func coordinator(
        database: DatabaseQueue,
        source: any ContactsSource
    ) -> AppLaunchCoordinator {
        let now = self.now
        return AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: {
                    try await AppRuntime.makeProduction(database: database)
                },
                contactsSource: source,
                clock: { now }
            )
        )
    }

    static let systemContact = SystemContact(
        identifier: "launch-contact",
        givenName: "Leia",
        familyName: "Organa",
        phoneNumbers: ["+1 555 010 2000"],
        emailAddresses: ["leia@example.com"]
    )
}

private enum LaunchTestError: Error {
    case openFailed
    case fetchFailed
}

actor ScriptedLaunchContactsSource: ContactsSource {
    struct Counts: Equatable {
        let current: Int
        let requests: Int
        let fetches: Int
    }
    private var status: ContactsAuthorizationStatus
    private let requestResult: ContactsAuthorizationStatus?
    private let contacts: [SystemContact]
    private var fetchFailuresRemaining: Int
    private var currentCount = 0
    private var requestCount = 0
    private var fetchCount = 0
    init(
        status: ContactsAuthorizationStatus,
        contacts: [SystemContact] = [],
        fetchFailuresRemaining: Int = 0,
        requestResult: ContactsAuthorizationStatus? = nil
    ) {
        self.status = status
        self.contacts = contacts
        self.fetchFailuresRemaining = fetchFailuresRemaining
        self.requestResult = requestResult
    }
    func currentAuthorization() async -> ContactsAuthorizationStatus {
        currentCount += 1
        return status
    }
    func requestAccess() async throws -> ContactsAuthorizationStatus {
        requestCount += 1
        if status == .notDetermined {
            status = requestResult ?? .authorized
        }
        return status
    }
    func fetchAllContacts() async throws -> [SystemContact] {
        fetchCount += 1
        if fetchFailuresRemaining > 0 {
            fetchFailuresRemaining -= 1
            throw LaunchTestError.fetchFailed
        }
        return contacts
    }
    func counts() -> Counts {
        Counts(current: currentCount, requests: requestCount, fetches: fetchCount)
    }
}
private actor TransientRuntimeFactory {
    private let database: DatabaseQueue
    private var attempts = 0
    init(database: DatabaseQueue) { self.database = database }
    func makeRuntime() async throws -> AppRuntime {
        attempts += 1
        if attempts == 1 {
            throw LaunchTestError.openFailed
        }
        return try await AppRuntime.makeProduction(database: database)
    }
    func attemptCount() -> Int { attempts }
}
private actor BlockingAuthorizationContactsSource: ContactsSource {
    private let contacts: [SystemContact]
    private var fetchFailuresRemaining: Int
    private var currentStarted = false
    private var currentStartWaiter: CheckedContinuation<Void, Never>?,
                currentFinishWaiter: CheckedContinuation<Void, Never>?
    private var currentCount = 0, requestCount = 0, fetchCount = 0
    init(contacts: [SystemContact], fetchFailuresRemaining: Int = 0) {
        self.contacts = contacts
        self.fetchFailuresRemaining = fetchFailuresRemaining
    }
    func currentAuthorization() async -> ContactsAuthorizationStatus {
        currentCount += 1
        guard currentCount == 1 else { return .authorized }
        currentStarted = true
        currentStartWaiter?.resume()
        currentStartWaiter = nil
        await withCheckedContinuation { continuation in
            currentFinishWaiter = continuation
        }
        return .authorized
    }
    func requestAccess() async throws -> ContactsAuthorizationStatus {
        requestCount += 1
        return .authorized
    }
    func fetchAllContacts() async throws -> [SystemContact] {
        fetchCount += 1
        if fetchFailuresRemaining > 0 {
            fetchFailuresRemaining -= 1
            throw LaunchTestError.fetchFailed
        }
        return contacts
    }
    func waitUntilCurrentAuthorizationStarts() async {
        guard !currentStarted else { return }
        await withCheckedContinuation { continuation in
            currentStartWaiter = continuation
        }
    }
    func finishCurrentAuthorization() { currentFinishWaiter?.resume(); currentFinishWaiter = nil }
    func counts() -> ScriptedLaunchContactsSource.Counts {
        .init(current: currentCount, requests: requestCount, fetches: fetchCount)
    }
}
private actor BlockingRetryRuntimeFactory {
    private let database: DatabaseQueue
    private var attempts = 0
    private var retryStarted = false
    private var retryStartWaiter: CheckedContinuation<Void, Never>?
    private var retryFinishWaiter: CheckedContinuation<Void, Never>?
    init(database: DatabaseQueue) {
        self.database = database
    }
    func makeRuntime() async throws -> AppRuntime {
        attempts += 1
        guard attempts > 1 else {
            throw LaunchTestError.openFailed
        }
        retryStarted = true
        retryStartWaiter?.resume()
        retryStartWaiter = nil
        await withCheckedContinuation { continuation in
            retryFinishWaiter = continuation
        }
        return try await AppRuntime.makeProduction(database: database)
    }
    func waitUntilRetryStarts() async {
        guard !retryStarted else { return }
        await withCheckedContinuation { continuation in
            retryStartWaiter = continuation
        }
    }
    func finishRetry() {
        retryFinishWaiter?.resume()
        retryFinishWaiter = nil
    }
    func attemptCount() -> Int { attempts }
}
