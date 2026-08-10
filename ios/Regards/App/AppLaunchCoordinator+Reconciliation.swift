import Foundation

/// Reconciliation triggers (ARCHITECTURE.md §7 "Re-import & reconciliation",
/// PR21): foreground, `CNContactStoreDidChange`, and the single-flight pass
/// runner both of those (and `start()`'s launch-time call) share. Split from
/// `AppLaunchCoordinator.swift` to keep that file's primary type body under
/// the lint length limit — these members can't be `private` because of the
/// file split, but nothing outside `AppLaunchCoordinator` itself calls them
/// except `RootView`'s `handleSceneActivation()`, which was already
/// non-private.
extension AppLaunchCoordinator {
    /// Called when the scene becomes active again (app foregrounded). A
    /// no-op before the runtime is ready or while onboarding is still in
    /// progress.
    func handleSceneActivation() async {
        guard phase == .ready, let runtime, let dependencies else { return }
        await reconcileNow(runtime: runtime, dependencies: dependencies)
    }

    func beginObservingContactStoreChanges(dependencies: Dependencies) {
        guard changeObservationTask == nil else { return }
        let stream = dependencies.contactsSource.changeNotifications()
        changeObservationTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                guard let runtime = self.runtime else {
                    // No runtime to reconcile against right now (e.g. mid-
                    // `retry()`) — remember the notification instead of
                    // dropping it; `start()` replays it once `runtime` is
                    // set again (see `pendingStoreChangeReplay`).
                    self.pendingStoreChangeReplay = true
                    continue
                }
                await self.reconcileNow(runtime: runtime, dependencies: dependencies)
            }
        }
    }

    /// Single-flight + coalesced: launch, foreground, and store-change can
    /// all try to trigger a pass around the same moment (e.g. a foreground
    /// racing the store-change notification it woke up to handle), and
    /// running `.reconcile()` concurrently against the same database wastes
    /// a full enumeration twice and turns a legitimate concurrent insert
    /// into a spurious UNIQUE-constraint "failed" count. `reconciliationTask`
    /// is the "isReconciling" gate: a caller that arrives while it's non-nil
    /// sets `reconciliationPending` and awaits that *same* in-flight task,
    /// which loops for exactly one more pass once the current one finishes
    /// instead of starting a second one — so every caller still sees a pass
    /// that started at-or-after its own trigger by the time it returns.
    func reconcileNow(runtime: AppRuntime, dependencies: Dependencies) async {
        if let inFlight = reconciliationTask {
            reconciliationPending = true
            recordReconciliationCoalesce()
            await inFlight.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runReconciliationPasses(runtime: runtime, dependencies: dependencies)
        }
        reconciliationTask = task
        await task.value
    }

    private func runReconciliationPasses(runtime: AppRuntime, dependencies: Dependencies) async {
        repeat {
            reconciliationPending = false
            await performOneReconciliationPass(runtime: runtime, dependencies: dependencies)
        } while reconciliationPending
        reconciliationTask = nil
    }

    private func performOneReconciliationPass(runtime: AppRuntime, dependencies: Dependencies) async {
        let reconciler = ContactsReconciler(
            source: dependencies.contactsSource,
            repo: runtime.environment.contacts,
            clock: dependencies.clock
        )
        do {
            let result = try await reconciler.reconcile(previouslyMissingRefs: previouslyMissingContactRefs)
            previouslyMissingContactRefs = result.missingRefs
            Self.reconciliationLog.info("""
                reconciliation complete: imported=\(result.imported) refreshed=\(result.refreshed) \
                archived=\(result.archived) unarchived=\(result.unarchived) failed=\(result.failed)
                """)
        } catch {
            // No sweep ran this pass, so there's nothing newly-confirmed as
            // missing — reset rather than leave stale refs from a prior
            // pass sitting around waiting to be "confirmed" by an unrelated
            // later pass's coincidentally-overlapping miss.
            previouslyMissingContactRefs = []
            Self.reconciliationLog.error("reconciliation failed: \(error, privacy: .private)")
        }
        recordReconciliationPass()
    }

    private static let reconciliationLog = RegardsLogger.feature("AppLaunchCoordinator")
}
