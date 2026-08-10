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

    /// Backing storage for `reconciliationCount`/`reconciliationCoalesceCount`
    /// below. Nested and `private` on purpose, unlike the file-split
    /// properties further down: `AppLaunchCoordinator+Reconciliation.swift`
    /// can only advance these counts through `recordReconciliationPass()` /
    /// `recordReconciliationCoalesce()`, never assign them directly. Kept as
    /// a plain (non-`@ObservationIgnored`) stored property so reads through
    /// the computed properties below still register with `@Observable`
    /// tracking — `RootView` depends on that to re-render `RegardsTabRoot`
    /// with a fresh `reconciliationGeneration` after every pass.
    private struct ReconciliationCounters {
        var passes = 0
        var coalesces = 0
    }
    private var reconciliationCounters = ReconciliationCounters()

    /// Completed reconciliation passes (launch + foreground + store-change).
    /// `AllContactsScreen` reloads when this changes (via `RootView` →
    /// `RegardsTabRoot`'s `reconciliationGeneration`); tests also await a
    /// specific pass deterministically instead of sleeping.
    var reconciliationCount: Int { reconciliationCounters.passes }
    /// Incremented each time a trigger arrived while a pass was already in
    /// flight and coalesced into it instead of starting a concurrent one
    /// (fix 9). Test-only signal, same role as `reconciliationCount`.
    var reconciliationCoalesceCount: Int { reconciliationCounters.coalesces }

    /// Called only from `AppLaunchCoordinator+Reconciliation.swift`.
    func recordReconciliationPass() {
        reconciliationCounters.passes += 1
    }

    /// Called only from `AppLaunchCoordinator+Reconciliation.swift`.
    func recordReconciliationCoalesce() {
        reconciliationCounters.coalesces += 1
    }

    /// Set by `beginObservingContactStoreChanges` when a `CNContactStoreDidChange`
    /// notification arrives while `runtime` is `nil` (e.g. mid-`retry()`) — see
    /// that method's guard. `continue`-ing past it there would drop the
    /// notification for good; this flag lets `start()` replay it into exactly
    /// one reconciliation pass once a runtime exists again, instead of the
    /// change sitting unaddressed until some unrelated later trigger.
    @ObservationIgnored var pendingStoreChangeReplay = false

    // Not `private`: AppLaunchCoordinator+Reconciliation.swift reads/writes
    // these across the file split (see that file's header comment). Still
    // `internal`, i.e. module-scoped like everything else in this app
    // target — never exposed outside `AppLaunchCoordinator` itself in
    // practice, just not enforced by the compiler across the split. Unlike
    // the counters above, nothing outside the coordinator reads these, so
    // there's no external write-protection guarantee to restore.
    @ObservationIgnored let dependencies: Dependencies?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var onboardingActionGeneration = 0
    @ObservationIgnored var changeObservationTask: Task<Void, Never>?
    /// Non-nil while a reconciliation pass is in flight — the "isReconciling"
    /// gate. A concurrent trigger joins this task instead of starting a
    /// second pass.
    @ObservationIgnored var reconciliationTask: Task<Void, Never>?
    /// Set by a trigger that arrived while `reconciliationTask` was already
    /// running; the in-flight loop checks this after each pass and runs
    /// exactly one more before clearing `reconciliationTask`, coalescing any
    /// number of overlapping triggers into at most one extra pass.
    @ObservationIgnored var reconciliationPending = false

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

    /// Not `private`: `AppLaunchCoordinator+DebugLaunch.swift` calls this
    /// across the file split (see that file's header comment).
    init(mockRuntime: AppRuntime) {
        self.phase = .ready
        self.runtime = mockRuntime
        self.dependencies = nil
        self.didStart = true
    }

    deinit {
        changeObservationTask?.cancel()
        reconciliationTask?.cancel()
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

    // `configuredForCurrentProcess()` (the DEBUG launch-argument factory)
    // lives in AppLaunchCoordinator+DebugLaunch.swift.

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
            // A store-change notification arriving while `runtime` was `nil`
            // (see `pendingStoreChangeReplay`'s doc comment) gets exactly one
            // catch-up pass now that there's a runtime to run it against.
            await replayPendingStoreChangeIfNeeded(runtime: runtime, dependencies: dependencies)
            guard profile.onboardingCompletedAt == nil else {
                // Subscribe *before* the launch reconcile below, not after:
                // that reconcile can run long (up to a full Contacts
                // enumeration, moved off the cooperative pool by R25), and a
                // CNContactStoreDidChange landing during it must be caught by
                // the listener rather than lost until the next foreground.
                // Flipping `phase` first still means the tab root appears
                // immediately — neither of these delays that.
                phase = .ready
                beginObservingContactStoreChanges(dependencies: dependencies)
                await reconcileNow(runtime: runtime, dependencies: dependencies)
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

        let result: ContactsImporter.Result
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
            result = try await importer.runFirstLaunchImport()
        } catch {
            statusMessage = Self.importFailureMessage
            canContinueWithoutContacts = true
            return
        }
        guard !Self.importEffectivelyFailed(result) else {
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

    // Reconciliation triggers (`handleSceneActivation`, store-change
    // observation, single-flight coalescing) live in
    // AppLaunchCoordinator+Reconciliation.swift.

    /// Drains `pendingStoreChangeReplay` into exactly one reconciliation
    /// pass, now that `runtime` is set. A no-op when nothing was pending —
    /// which is the common case, since `beginObservingContactStoreChanges`
    /// only ever sets the flag if a notification arrives during the narrow
    /// window this coordinator has no runtime to reconcile against.
    private func replayPendingStoreChangeIfNeeded(
        runtime: AppRuntime,
        dependencies: Dependencies
    ) async {
        guard pendingStoreChangeReplay else { return }
        pendingStoreChangeReplay = false
        await reconcileNow(runtime: runtime, dependencies: dependencies)
    }

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

        let result: ContactsImporter.Result
        do {
            let importer = ContactsImporter(
                source: dependencies.contactsSource,
                repo: runtime.environment.contacts,
                clock: dependencies.clock
            )
            result = try await importer.runFirstLaunchImport()
        } catch {
            statusMessage = Self.importFailureMessage
            canContinueWithoutContacts = true
            return
        }
        guard !Self.importEffectivelyFailed(result) else {
            statusMessage = Self.importFailureMessage
            canContinueWithoutContacts = true
            return
        }

        await completeOnboardingAfterImport(runtime: runtime, clock: dependencies.clock)
    }

    /// R35 made a single row's write failure non-throwing — logged and
    /// counted in `Result.failed` instead of aborting the pass — which is
    /// correct when the pass still imported *something*. But if every
    /// attempted row failed, `runFirstLaunchImport()` still returns
    /// normally with `imported == 0`, and silently completing onboarding
    /// on that result would leave All Contacts empty with no visible sign
    /// anything went wrong.
    private static func importEffectivelyFailed(_ result: ContactsImporter.Result) -> Bool {
        result.failed > 0 && result.imported == 0
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
