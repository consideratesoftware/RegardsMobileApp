import Foundation
import SwiftUI
import Testing
@testable import Regards

/// No test previously exercised `RootView`'s actual `.onChange(of: scenePhase)`
/// binding to `AppLaunchCoordinator.handleSceneActivation()` — every
/// reconciliation test called `handleSceneActivation()` directly. This hosts
/// the real `RootView`, drives genuine SwiftUI `scenePhase` environment
/// transitions through an observable harness, and proves the coordinator's
/// reconciliation count reacts correctly to both shapes of transition into
/// `.active`: a real background→active foreground (round 7) reconciles, and
/// an inactive→active blip — Control Center, share sheet, a notification
/// banner dismissing, none of which ever leave the app backgrounded — does
/// not (round 8).
@MainActor
struct RootViewSceneActivationTests {
    let now = Date(timeIntervalSince1970: 1_785_600_000)

    @Test("A genuine background→active foreground triggers handleSceneActivation")
    func backgroundToActiveEdgeTriggersReconciliation() async throws {
        let (launch, model, window) = try await makeStartedHarness()
        let countAfterLaunch = launch.reconciliationCount

        model.scenePhase = .background
        // Forces SwiftUI to actually commit a render pass against the
        // `.background` value before moving on — two assignments back to
        // back with no render pass between them risk SwiftUI coalescing
        // them and only ever diffing directly from the harness's initial
        // `.active` to the final `.active`, silently skipping the
        // intermediate state this test means to exercise. `layoutIfNeeded()`
        // alone isn't reliable here (it forces UIKit's Auto Layout pass, not
        // SwiftUI's own render cycle); the same run-loop pump `makeStartedHarness`
        // already relies on for `.task` is what actually commits it.
        pumpRunLoopBriefly()
        model.scenePhase = .active

        #expect(await eventuallyPumpingRunLoop { launch.reconciliationCount > countAfterLaunch })
        #expect(launch.reconciliationCount == countAfterLaunch + 1)

        window.isHidden = true
    }

    @Test("An inactive→active blip (Control Center, share sheet) does not trigger reconciliation")
    func inactiveToActiveBlipDoesNotTriggerReconciliation() async throws {
        let (launch, model, window) = try await makeStartedHarness()
        let countAfterLaunch = launch.reconciliationCount

        // The scene never left the foreground here — no `.background` in
        // this sequence — so this must not reconcile. The pump between the
        // two assignments forces SwiftUI to actually commit and diff the
        // `.inactive` value, rather than risk coalescing straight from
        // `.active` to `.active` and testing nothing (see
        // `backgroundToActiveEdgeTriggersReconciliation`'s comment above).
        model.scenePhase = .inactive
        pumpRunLoopBriefly()
        model.scenePhase = .active

        // Waiting for a *negative* can't use the same "eventually true"
        // shape as the positive case above: instead, wait (bounded, well
        // short of the 15s ceiling other waits in this suite use, since a
        // regression here would fire near-instantly) for the count to
        // become what an *incorrect* ungated implementation would produce,
        // and assert that never happens.
        let reconciledSpuriously = await eventuallyPumpingRunLoop(maxIterations: 30) {
            launch.reconciliationCount > countAfterLaunch
        }
        #expect(!reconciledSpuriously, "an inactive→active blip must not trigger a reconciliation pass")
        #expect(launch.reconciliationCount == countAfterLaunch)

        window.isHidden = true
    }

    /// Shared setup: starts a real `RootView` hosted in a `UIWindow`, waits
    /// for `RootView`'s own launch `.task` to complete pass #1, and hands
    /// back the pieces each test drives independently from there.
    private func makeStartedHarness() async throws -> (
        launch: AppLaunchCoordinator, model: ScenePhaseModel, window: UIWindow
    ) {
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
        model.scenePhase = .active

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

        return (launch, model, window)
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
