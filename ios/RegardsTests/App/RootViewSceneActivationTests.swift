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

        // `RootView`'s own `.task` calls `launch.start()` on first
        // appearance, independent of `scenePhase` — that's pass #1.
        #expect(await eventually { launch.reconciliationCount >= 1 })
        let countAfterLaunch = launch.reconciliationCount

        model.scenePhase = .active

        #expect(await eventually { launch.reconciliationCount > countAfterLaunch })
        #expect(launch.reconciliationCount == countAfterLaunch + 1)

        window.isHidden = true
    }
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
