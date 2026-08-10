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
    private(set) var onboardingCompletionPending = false
    /// Completed reconciliation passes (launch + foreground + store-change).
    /// Exposed so tests can await a specific pass deterministically instead
    /// of sleeping; the UI never reads it.
    private(set) var reconciliationCount = 0

    @ObservationIgnored private let dependencies: Dependencies?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var onboardingActionGeneration = 0
    @ObservationIgnored private var changeObservationTask: Task<Void, Never>?

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
                    let environment = try await Task.detached(priority: .userInitiated) {
                        try ProductionRepositoryFactory.makeFileBackedEnvironment()
                    }.value
                    return try await AppRuntime.makeProduction(environment: environment)
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
                        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
                        return try await AppRuntime.makeProduction(environment: environment)
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
                        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
                        return try await AppRuntime.makeProduction(environment: environment)
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
                // Flip the phase first so the tab root appears immediately —
                // reconciliation (up to a full Contacts enumeration, moved
                // off the cooperative pool by R25) never delays it — then
                // reconcile this launch and start listening for foreground
                // and CNContactStoreDidChange triggers.
                phase = .ready
                await reconcileNow(runtime: runtime, dependencies: dependencies)
                beginObservingContactStoreChanges(dependencies: dependencies)
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
        onboardingCompletionPending = false
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
        } catch {
            statusMessage = Self.importFailureMessage
            canContinueWithoutContacts = true
            return
        }

        await completeOnboardingAfterImport(runtime: runtime, clock: dependencies.clock)
    }

    func continueWithoutContacts() async {
        guard let runtime, let dependencies, !isImporting else { return }
        onboardingActionGeneration &+= 1
        isImporting = true
        defer { isImporting = false }

        do {
            try await completeOnboarding(runtime: runtime, clock: dependencies.clock)
        } catch {
            statusMessage = onboardingCompletionPending
                ? Self.postImportCompletionFailureMessage
                : "Regards couldn't save onboarding progress. Try again."
            canContinueWithoutContacts = true
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
        onboardingCompletionPending = false
        phase = .ready
        // First-launch import already read the full system store this
        // session, so skip an immediate re-reconcile here — foreground and
        // store-change triggers cover everything from this point on.
        if let dependencies {
            beginObservingContactStoreChanges(dependencies: dependencies)
        }
    }

    /// Called when the scene becomes active again (app foregrounded). A
    /// no-op before the runtime is ready or while onboarding is still in
    /// progress.
    func handleSceneActivation() async {
        guard phase == .ready, let runtime, let dependencies else { return }
        await reconcileNow(runtime: runtime, dependencies: dependencies)
    }

    private func beginObservingContactStoreChanges(dependencies: Dependencies) {
        guard changeObservationTask == nil else { return }
        let stream = dependencies.contactsSource.changeNotifications()
        changeObservationTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                guard let runtime = self.runtime else { continue }
                await self.reconcileNow(runtime: runtime, dependencies: dependencies)
            }
        }
    }

    private func reconcileNow(runtime: AppRuntime, dependencies: Dependencies) async {
        let reconciler = ContactsReconciler(
            source: dependencies.contactsSource,
            repo: runtime.environment.contacts,
            clock: dependencies.clock
        )
        do {
            let result = try await reconciler.reconcile()
            Self.log.info("""
                reconciliation complete: imported=\(result.imported) refreshed=\(result.refreshed) \
                archived=\(result.archived) unarchived=\(result.unarchived) failed=\(result.failed)
                """)
        } catch {
            Self.log.error("reconciliation failed: \(error, privacy: .private)")
        }
        reconciliationCount += 1
    }

    private static let log = RegardsLogger.feature("AppLaunchCoordinator")

    private func importAuthorizedContacts(
        runtime: AppRuntime,
        dependencies: Dependencies
    ) async {
        guard !isImporting else { return }
        isImporting = true
        statusMessage = nil
        canContinueWithoutContacts = false
        onboardingCompletionPending = false
        defer { isImporting = false }

        do {
            let importer = ContactsImporter(
                source: dependencies.contactsSource,
                repo: runtime.environment.contacts,
                clock: dependencies.clock
            )
            _ = try await importer.runFirstLaunchImport()
        } catch {
            statusMessage = Self.importFailureMessage
            canContinueWithoutContacts = true
            return
        }

        await completeOnboardingAfterImport(runtime: runtime, clock: dependencies.clock)
    }

    private func completeOnboardingAfterImport(
        runtime: AppRuntime,
        clock: @Sendable () -> Date
    ) async {
        onboardingCompletionPending = true
        do {
            try await completeOnboarding(runtime: runtime, clock: clock)
        } catch {
            statusMessage = Self.postImportCompletionFailureMessage
            canContinueWithoutContacts = true
        }
    }

    private static let importFailureMessage =
        "Regards couldn't finish importing contacts. Retry to resume, or continue without contacts."
    private static let postImportCompletionFailureMessage =
        "Contacts were imported, but Regards couldn't finish setup. Try again."
}

#if DEBUG
private enum FirstLaunchUITestContactsOutcome: String {
    case authorized
    case denied
    case deniedAtLaunch = "denied-at-launch"
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
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        return try await AppRuntime.makeProduction(environment: environment)
    }
}

private actor FirstLaunchUITestContactsSource: ContactsSource {
    private let outcome: FirstLaunchUITestContactsOutcome
    private var status: ContactsAuthorizationStatus = .notDetermined
    private var remainingFetchFailures: Int

    init(outcome: FirstLaunchUITestContactsOutcome) {
        self.outcome = outcome
        if outcome == .deniedAtLaunch {
            self.status = .denied
        }
        self.remainingFetchFailures = outcome == .importFailsOnce ? 1 : 0
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus { status }

    func requestAccess() async throws -> ContactsAuthorizationStatus {
        status = outcome == .denied || outcome == .deniedAtLaunch ? .denied : .authorized
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
