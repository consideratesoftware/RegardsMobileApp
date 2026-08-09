import Foundation
import Observation

/// Owns the one-time transition from the launch screen into the persisted app
/// runtime. The coordinator keeps database and permission work out of SwiftUI
/// views while exposing each recoverable launch state explicitly.
@Observable @MainActor
final class AppLaunchCoordinator {
    enum Phase: Equatable {
        case loading
        case onboarding
        case ready
        case failed
    }

    struct Dependencies: Sendable {
        let makeRuntime: @Sendable () async throws -> AppRuntime
        let contactsSource: any ContactsSource
        let clock: @Sendable () -> Date
    }

    private(set) var phase: Phase
    private(set) var runtime: AppRuntime?
    private(set) var isImporting = false
    private(set) var statusMessage: String?
    private(set) var canContinueWithoutContacts = false

    @ObservationIgnored private let dependencies: Dependencies?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var onboardingActionGeneration = 0

    init(dependencies: Dependencies) {
        self.phase = .loading
        self.dependencies = dependencies
    }

#if DEBUG
    init(dependencies: Dependencies, testingPhase: Phase) {
        self.phase = testingPhase
        self.dependencies = dependencies
        self.didStart = true
    }
#endif

    private init(mockRuntime: AppRuntime) {
        self.phase = .ready
        self.runtime = mockRuntime
        self.dependencies = nil
        self.didStart = true
    }

    static func production() -> AppLaunchCoordinator {
        AppLaunchCoordinator(
            dependencies: Dependencies(
                makeRuntime: {
                    let database = try await Task.detached(priority: .userInitiated) {
                        try DatabaseFactory.makeDatabase()
                    }.value
                    return try await AppRuntime.makeProduction(database: database)
                },
                contactsSource: CNContactsSource(),
                clock: { Date() }
            )
        )
    }

#if DEBUG
    static func configuredForCurrentProcess() -> AppLaunchCoordinator {
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--regards-mock-runtime") {
            return AppLaunchCoordinator(
                mockRuntime: .makeMock(
                    includeDuplicateFixture:
                        environment["REGARDS_UI_TEST_DUPLICATE_FIXTURE"] == "1"
                )
            )
        }
        if arguments.contains("--regards-launch-fails-once") {
            let runtimeFactory = FirstLaunchUITestRuntimeFactory()
            return AppLaunchCoordinator(
                dependencies: Dependencies(
                    makeRuntime: { try await runtimeFactory.makeRuntime() },
                    contactsSource: FirstLaunchUITestContactsSource(outcome: .authorized),
                    clock: { Date(timeIntervalSince1970: 1_785_600_000) }
                )
            )
        }
        if arguments.contains("--regards-first-launch-runtime") {
            let contactsOutcome = FirstLaunchUITestContactsOutcome(
                rawValue: environment["REGARDS_UI_TEST_CONTACTS_OUTCOME"] ?? "authorized"
            ) ?? .authorized
            return AppLaunchCoordinator(
                dependencies: Dependencies(
                    makeRuntime: {
                        let database = try DatabaseFactory.makeInMemoryDatabase()
                        return try await AppRuntime.makeProduction(database: database)
                    },
                    contactsSource: FirstLaunchUITestContactsSource(outcome: contactsOutcome),
                    clock: { Date(timeIntervalSince1970: 1_785_600_000) }
                )
            )
        }
        if arguments.contains("--regards-ready-without-runtime") {
            return AppLaunchCoordinator(
                dependencies: Dependencies(
                    makeRuntime: {
                        let database = try DatabaseFactory.makeInMemoryDatabase()
                        return try await AppRuntime.makeProduction(database: database)
                    },
                    contactsSource: FirstLaunchUITestContactsSource(outcome: .authorized),
                    clock: { Date(timeIntervalSince1970: 1_785_600_000) }
                ),
                testingPhase: .ready
            )
        }
        return production()
    }
#else
    static func configuredForCurrentProcess() -> AppLaunchCoordinator {
        production()
    }
#endif

    func start() async {
        guard !didStart, let dependencies else { return }
        didStart = true
        phase = .loading
        statusMessage = nil

        do {
            let runtime = try await dependencies.makeRuntime()
            try Task.checkCancellation()
            var profile = try await runtime.environment.profile.fetch()
            try Task.checkCancellation()
            let now = dependencies.clock()
            if profile.trialStartedAt == nil {
                profile.trialStartedAt = now
                if profile.entitlementTier == .free {
                    profile.entitlementTier = .trial
                    profile.entitlementRefreshedAt = now
                }
                try await runtime.environment.profile.save(profile)
                try Task.checkCancellation()
            }

            self.runtime = runtime
            guard profile.onboardingCompletedAt == nil else {
                phase = .ready
                return
            }

            phase = .onboarding
            let actionGeneration = onboardingActionGeneration
            let authorization = await dependencies.contactsSource.currentAuthorization()
            guard phase == .onboarding,
                  !isImporting,
                  onboardingActionGeneration == actionGeneration else { return }
            try Task.checkCancellation()
            switch authorization {
            case .authorized, .limited:
                await importAuthorizedContacts(runtime: runtime, dependencies: dependencies)
            case .denied, .restricted:
                statusMessage = "Contacts access isn't available. You can continue without importing."
                canContinueWithoutContacts = true
            case .notDetermined:
                break
            }
        } catch is CancellationError {
            runtime = nil
            statusMessage = "Regards couldn't finish opening its local data. Try again."
            phase = .failed
        } catch {
            statusMessage = "Regards couldn't open its local data. Try again."
            phase = .failed
        }
    }

    func retry() async {
        guard phase == .failed || (phase == .ready && runtime == nil) else { return }
        phase = .loading
        didStart = false
        runtime = nil
        await start()
    }

    func requestContactsAndImport() async {
        guard let runtime, let dependencies, !isImporting else { return }
        onboardingActionGeneration &+= 1
        isImporting = true
        statusMessage = nil
        canContinueWithoutContacts = false
        defer { isImporting = false }

        do {
            let status = try await dependencies.contactsSource.requestAccess()
            guard status == .authorized || status == .limited else {
                statusMessage = "Contacts access wasn't granted. You can continue without importing."
                canContinueWithoutContacts = true
                return
            }

            let importer = ContactsImporter(
                source: dependencies.contactsSource,
                repo: runtime.environment.contacts,
                clock: dependencies.clock
            )
            _ = try await importer.runFirstLaunchImport()
            try await completeOnboarding(runtime: runtime, clock: dependencies.clock)
        } catch {
            statusMessage = Self.importFailureMessage
            canContinueWithoutContacts = true
        }
    }

    func continueWithoutContacts() async {
        guard let runtime, let dependencies, !isImporting else { return }
        onboardingActionGeneration &+= 1
        isImporting = true
        defer { isImporting = false }

        do {
            try await completeOnboarding(runtime: runtime, clock: dependencies.clock)
        } catch {
            statusMessage = "Regards couldn't save onboarding progress. Try again."
        }
    }

    private func completeOnboarding(
        runtime: AppRuntime,
        clock: @Sendable () -> Date
    ) async throws {
        var profile = try await runtime.environment.profile.fetch()
        profile.onboardingCompletedAt = clock()
        try await runtime.environment.profile.save(profile)
        statusMessage = nil
        canContinueWithoutContacts = false
        phase = .ready
    }

    private func importAuthorizedContacts(
        runtime: AppRuntime,
        dependencies: Dependencies
    ) async {
        guard !isImporting else { return }
        isImporting = true
        statusMessage = nil
        canContinueWithoutContacts = false
        defer { isImporting = false }

        do {
            let importer = ContactsImporter(
                source: dependencies.contactsSource,
                repo: runtime.environment.contacts,
                clock: dependencies.clock
            )
            _ = try await importer.runFirstLaunchImport()
            try await completeOnboarding(runtime: runtime, clock: dependencies.clock)
        } catch {
            statusMessage = Self.importFailureMessage
            canContinueWithoutContacts = true
        }
    }

    private static let importFailureMessage =
        "Regards couldn't finish importing contacts. Retry to resume, or continue without contacts."
}

#if DEBUG
private enum FirstLaunchUITestContactsOutcome: String {
    case authorized
    case denied
    case importFailsOnce = "import-fails-once"
}

private enum FirstLaunchUITestContactsError: Error {
    case fetchFailed
}

private enum FirstLaunchUITestRuntimeError: Error {
    case openFailed
}

private actor FirstLaunchUITestRuntimeFactory {
    private var shouldFail = true

    func makeRuntime() async throws -> AppRuntime {
        if shouldFail {
            shouldFail = false
            throw FirstLaunchUITestRuntimeError.openFailed
        }
        let database = try DatabaseFactory.makeInMemoryDatabase()
        return try await AppRuntime.makeProduction(database: database)
    }
}

private actor FirstLaunchUITestContactsSource: ContactsSource {
    private let outcome: FirstLaunchUITestContactsOutcome
    private var status: ContactsAuthorizationStatus = .notDetermined
    private var remainingFetchFailures: Int

    init(outcome: FirstLaunchUITestContactsOutcome) {
        self.outcome = outcome
        self.remainingFetchFailures = outcome == .importFailsOnce ? 1 : 0
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus { status }

    func requestAccess() async throws -> ContactsAuthorizationStatus {
        status = outcome == .denied ? .denied : .authorized
        return status
    }

    func fetchAllContacts() async throws -> [SystemContact] {
        if remainingFetchFailures > 0 {
            remainingFetchFailures -= 1
            throw FirstLaunchUITestContactsError.fetchFailed
        }
        return [
            SystemContact(
                identifier: "ui-test-contact",
                givenName: "Leia",
                familyName: "Organa",
                phoneNumbers: ["+1 555 010 2000"],
                emailAddresses: ["leia@example.com"]
            ),
        ]
    }
}
#endif
