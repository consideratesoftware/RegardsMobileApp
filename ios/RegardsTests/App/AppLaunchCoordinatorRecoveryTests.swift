import Foundation
import GRDB
import Testing
@testable import Regards

@MainActor
struct AppLaunchCoordinatorRecoveryTests {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_785_600_000)

    @Test("A cancelled production open becomes visibly retryable")
    func cancelledProductionOpenCanRetry() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let runtimeFactory = CancellableRecoveryRuntimeFactory(database: database)
        let source = RecoveryContactsSource(status: .notDetermined)
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await runtimeFactory.makeRuntime() },
                contactsSource: source,
                clock: { Self.now }
            )
        )

        let firstStart = Task { await launch.start() }
        await runtimeFactory.waitUntilFirstAttemptStarts()
        firstStart.cancel()
        await runtimeFactory.finishFirstAttempt()
        await firstStart.value

        #expect(launch.phase == .failed)
        #expect(launch.runtime == nil)
        #expect(launch.statusMessage != nil)

        await launch.retry()

        #expect(launch.phase == .onboarding)
        #expect(launch.runtime != nil)
        #expect(await runtimeFactory.attemptCount() == 2)
    }

    @Test("A failed browse-only save stays recoverable and retries")
    func continueWithoutContactsSaveFailureCanRetry() async throws {
        let profile = RetryingRecoveryProfileRepository(
            profile: Self.startedTrialProfile,
            failuresRemaining: 1
        )
        let source = RecoveryContactsSource(status: .denied)
        let launch = coordinator(runtime: runtime(profile: profile), source: source)

        await launch.start()
        await launch.continueWithoutContacts()

        #expect(launch.phase == .onboarding)
        #expect(launch.canContinueWithoutContacts)
        #expect(!launch.isImporting)
        #expect(launch.statusMessage != nil)
        #expect(await profile.saveCount() == 1)

        await launch.continueWithoutContacts()

        #expect(launch.phase == .ready)
        #expect(await profile.saveCount() == 2)
        #expect(try await profile.fetch().onboardingCompletedAt == Self.now)
    }

    @Test("Double-tapping import starts one permission and import pass")
    func doubleImportTapStartsOnePass() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let source = BlockingRecoveryRequestContactsSource(contacts: [Self.systemContact])
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(database: database) },
                contactsSource: source,
                clock: { Self.now }
            )
        )
        await launch.start()

        let firstTap = Task { await launch.requestContactsAndImport() }
        await source.waitUntilRequestStarts()
        await launch.requestContactsAndImport()
        await source.finishRequest()
        await firstTap.value

        #expect(launch.phase == .ready)
        #expect(await source.counts() == .init(current: 2, requests: 1, fetches: 1))
        let runtime = try #require(launch.runtime)
        #expect(try await runtime.environment.contacts.fetchAll().count == 1)
    }

    @Test("Double-tapping continue starts one profile save")
    func doubleContinueTapStartsOneSave() async throws {
        let profile = BlockingRecoveryProfileRepository(profile: Self.startedTrialProfile)
        let source = RecoveryContactsSource(status: .denied)
        let launch = coordinator(runtime: runtime(profile: profile), source: source)
        await launch.start()

        let firstTap = Task { await launch.continueWithoutContacts() }
        await profile.waitUntilSaveStarts()
        await launch.continueWithoutContacts()
        await profile.finishSave()
        await firstTap.value

        #expect(launch.phase == .ready)
        #expect(await profile.saveCount() == 1)
    }

    @Test("An undecodable stored contact offers browse-only recovery")
    func corruptStoredContactCanContinueWithoutContacts() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let environment = AppEnvironment.makeProduction(database: database)
        let corruptContact = Contact(
            systemContactRef: "corrupt-stored-contact",
            displayName: "Corrupt Stored Contact"
        )
        try await environment.contacts.upsert(corruptContact)
        try await database.write { db in
            try db.execute(
                sql: "UPDATE Contact SET phonesJson = ? WHERE id = ?",
                arguments: ["[", corruptContact.id.uuidString]
            )
        }
        let source = RecoveryContactsSource(
            status: .authorized,
            contacts: [Self.systemContact]
        )
        let launch = coordinator(database: database, source: source)

        await launch.start()

        #expect(launch.phase == .onboarding)
        #expect(launch.statusMessage != nil)
        #expect(launch.canContinueWithoutContacts)
        #expect(!launch.isImporting)
        let runtime = try #require(launch.runtime)
        #expect(try await runtime.environment.profile.fetch().onboardingCompletedAt == nil)
        #expect(await source.counts() == .init(current: 2, requests: 0, fetches: 1))
        let persistedContactCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM Contact")
        }
        #expect(persistedContactCount == 1)

        await launch.continueWithoutContacts()

        #expect(launch.phase == .ready)
        #expect(try await runtime.environment.profile.fetch().onboardingCompletedAt == Self.now)
    }

    private func coordinator(
        runtime: AppRuntime,
        source: any ContactsSource
    ) -> AppLaunchCoordinator {
        AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { runtime },
                contactsSource: source,
                clock: { Self.now }
            )
        )
    }

    private func coordinator(
        database: DatabaseQueue,
        source: any ContactsSource
    ) -> AppLaunchCoordinator {
        AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(database: database) },
                contactsSource: source,
                clock: { Self.now }
            )
        )
    }

    private func runtime(profile: any UserProfileRepository) -> AppRuntime {
        let base = AppEnvironment.makeMock(now: Self.now)
        let environment = AppEnvironment(
            contacts: base.contacts,
            groups: base.groups,
            reminders: base.reminders,
            interactions: base.interactions,
            window: base.window,
            profile: profile
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Etc/UTC") ?? .current
        return AppRuntime(
            environment: environment,
            window: MockRepositories.defaultWindow,
            userCalendar: calendar,
            clock: { Self.now }
        )
    }

    private static let startedTrialProfile = UserProfile(
        entitlementTier: .trial,
        entitlementRefreshedAt: now,
        trialStartedAt: now
    )

    private static let systemContact = SystemContact(
        identifier: "recovery-contact",
        givenName: "Leia",
        familyName: "Organa",
        phoneNumbers: ["+1 555 010 2000"],
        emailAddresses: ["leia@example.com"]
    )
}

private enum LaunchRecoveryTestError: Error {
    case saveFailed
}

private actor RecoveryContactsSource: ContactsSource {
    struct Counts: Equatable {
        let current: Int
        let requests: Int
        let fetches: Int
    }

    private let status: ContactsAuthorizationStatus
    private let contacts: [SystemContact]
    private var currentCount = 0
    private var requestCount = 0
    private var fetchCount = 0

    init(status: ContactsAuthorizationStatus, contacts: [SystemContact] = []) {
        self.status = status
        self.contacts = contacts
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus {
        currentCount += 1
        return status
    }

    func requestAccess() async throws -> ContactsAuthorizationStatus {
        requestCount += 1
        return status
    }

    func fetchAllContacts() async throws -> [SystemContact] {
        fetchCount += 1
        return contacts
    }

    func counts() -> Counts {
        .init(current: currentCount, requests: requestCount, fetches: fetchCount)
    }
}

private actor CancellableRecoveryRuntimeFactory {
    private let database: DatabaseQueue
    private var attempts = 0
    private var firstAttemptStarted = false
    private var firstAttemptWaiter: CheckedContinuation<Void, Never>?
    private var firstAttemptGate: CheckedContinuation<Void, Never>?

    init(database: DatabaseQueue) {
        self.database = database
    }

    func makeRuntime() async throws -> AppRuntime {
        attempts += 1
        if attempts == 1 {
            firstAttemptStarted = true
            firstAttemptWaiter?.resume()
            firstAttemptWaiter = nil
            await withCheckedContinuation { continuation in
                firstAttemptGate = continuation
            }
        }
        return try await AppRuntime.makeProduction(database: database)
    }

    func waitUntilFirstAttemptStarts() async {
        guard !firstAttemptStarted else { return }
        await withCheckedContinuation { continuation in
            firstAttemptWaiter = continuation
        }
    }

    func finishFirstAttempt() {
        firstAttemptGate?.resume()
        firstAttemptGate = nil
    }

    func attemptCount() -> Int { attempts }
}

private actor RetryingRecoveryProfileRepository: UserProfileRepository {
    private var profile: UserProfile
    private var failuresRemaining: Int
    private var saves = 0

    init(profile: UserProfile, failuresRemaining: Int) {
        self.profile = profile
        self.failuresRemaining = failuresRemaining
    }

    func fetch() async throws -> UserProfile { profile }

    func save(_ profile: UserProfile) async throws {
        saves += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw LaunchRecoveryTestError.saveFailed
        }
        self.profile = profile
    }

    func saveCount() -> Int { saves }
}

private actor BlockingRecoveryProfileRepository: UserProfileRepository {
    private var profile: UserProfile
    private var saves = 0
    private var saveStarted = false
    private var saveStartWaiter: CheckedContinuation<Void, Never>?
    private var saveFinishWaiter: CheckedContinuation<Void, Never>?

    init(profile: UserProfile) {
        self.profile = profile
    }

    func fetch() async throws -> UserProfile { profile }

    func save(_ profile: UserProfile) async throws {
        saves += 1
        saveStarted = true
        saveStartWaiter?.resume()
        saveStartWaiter = nil
        await withCheckedContinuation { continuation in
            saveFinishWaiter = continuation
        }
        self.profile = profile
    }

    func waitUntilSaveStarts() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { continuation in
            saveStartWaiter = continuation
        }
    }

    func finishSave() {
        saveFinishWaiter?.resume()
        saveFinishWaiter = nil
    }

    func saveCount() -> Int { saves }
}

private actor BlockingRecoveryRequestContactsSource: ContactsSource {
    struct Counts: Equatable {
        let current: Int
        let requests: Int
        let fetches: Int
    }

    private let contacts: [SystemContact]
    private var status: ContactsAuthorizationStatus = .notDetermined
    private var requestStarted = false
    private var requestStartWaiter: CheckedContinuation<Void, Never>?
    private var requestFinishWaiter: CheckedContinuation<Void, Never>?
    private var currentCount = 0
    private var requestCount = 0
    private var fetchCount = 0

    init(contacts: [SystemContact]) {
        self.contacts = contacts
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus {
        currentCount += 1
        return status
    }

    func requestAccess() async throws -> ContactsAuthorizationStatus {
        requestCount += 1
        requestStarted = true
        requestStartWaiter?.resume()
        requestStartWaiter = nil
        await withCheckedContinuation { continuation in
            requestFinishWaiter = continuation
        }
        status = .authorized
        return status
    }

    func fetchAllContacts() async throws -> [SystemContact] {
        fetchCount += 1
        return contacts
    }

    func waitUntilRequestStarts() async {
        guard !requestStarted else { return }
        await withCheckedContinuation { continuation in
            requestStartWaiter = continuation
        }
    }

    func finishRequest() {
        requestFinishWaiter?.resume()
        requestFinishWaiter = nil
    }

    func counts() -> Counts {
        .init(current: currentCount, requests: requestCount, fetches: fetchCount)
    }
}
