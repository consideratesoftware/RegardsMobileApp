import Foundation
import SwiftUI
import Testing
@testable import Regards

/// No test previously exercised `RootView`'s actual `.onChange(of: scenePhase)`
/// binding to `AppLaunchCoordinator.handleSceneActivation()` — every
/// reconciliation test called `handleSceneActivation()` directly. This hosts
/// the real `RootView`, drives a genuine SwiftUI `scenePhase` environment
/// transition to `.active` through an observable harness, and proves the
/// coordinator's reconciliation count advances as a result.
@MainActor
struct RootViewSceneActivationTests {
    let now = Date(timeIntervalSince1970: 1_785_600_000)

    @Test("RootView's scenePhase binding triggers handleSceneActivation on .active")
    func scenePhaseBecomingActiveTriggersReconciliation() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let source = MutableContactsSource(status: .authorized, contacts: [])
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
                contactsSource: source,
                clock: { self.now }
            )
        )
        let model = ScenePhaseModel()
        model.scenePhase = .background

        let host = UIHostingController(rootView: ScenePhaseHarness(model: model, launch: launch))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        // `RootView`'s own `.task` calls `launch.start()` on first
        // appearance, independent of `scenePhase` — that's pass #1. Uses
        // `eventuallyPumpingRunLoop`, not the shared `eventually`: `.task`
        // fires off SwiftUI's own layout/appearance machinery, which needs
        // the run loop actually spinning to commit, and plain
        // `Task.yield()` (what `eventually` uses) doesn't pump it — without
        // this, the launch reconcile sometimes hadn't started by the time
        // a bounded yield loop gave up, making this test flaky.
        #expect(await eventuallyPumpingRunLoop { launch.reconciliationCount >= 1 })
        let countAfterLaunch = launch.reconciliationCount

        model.scenePhase = .active

        #expect(await eventuallyPumpingRunLoop { launch.reconciliationCount > countAfterLaunch })
        #expect(launch.reconciliationCount == countAfterLaunch + 1)

        window.isHidden = true
    }
}

/// Bounded, run-loop-pumping wait for state SwiftUI's own appearance/
/// layout machinery drives (like `.task` firing) — see the call site's
/// comment for why the shared `eventually` (`Task.yield()`-only) isn't
/// sufficient here. Ceiling of `maxIterations * 0.05s` (15s) so a
/// genuinely-broken binding fails the test instead of hanging it.
@MainActor
private func eventuallyPumpingRunLoop(
    maxIterations: Int = 300,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<maxIterations {
        if condition() { return true }
        await Task.yield()
        pumpRunLoopBriefly()
    }
    return condition()
}

/// `RunLoop.current` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — it can only be
/// read from a synchronous context, hence this non-`async` wrapper instead
/// of calling it directly inside `eventuallyPumpingRunLoop`'s loop.
@MainActor
private func pumpRunLoopBriefly() {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

@MainActor
private final class ScenePhaseModel: ObservableObject {
    @Published var scenePhase: ScenePhase = .active
}

private struct ScenePhaseHarness: View {
    @ObservedObject var model: ScenePhaseModel
    let launch: AppLaunchCoordinator

    var body: some View {
        RootView(launch: launch)
            .environment(\.scenePhase, model.scenePhase)
    }
}
