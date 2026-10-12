import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Regards

/// The behavior of the Settings notifications row that lives in the view, not
/// the view model: the scene turning active re-reads the permission. It hosts
/// the real `SettingsScreen` in a window with `DebugNotificationScheduling`,
/// so no system prompt is involved. The denied row's "open the settings URL"
/// is not here: a hosted SwiftUI button exposes no accessibility elements to a
/// unit test, so it can't be activated (see the TF-06 report for the seam).
///
/// Follows `RootViewSceneActivationTests`: a harness view feeds `scenePhase`
/// from an observable model, and waits pump the run loop so SwiftUI commits.
@MainActor
struct SettingsNotificationsHostingTests {

    @Test("The scene turning active re-reads a permission changed in iOS Settings")
    func sceneActivePicksUpIOSSettingsChange() async throws {
        let harness = try await Self.host(status: .denied)
        defer { harness.window.isHidden = true }
        #expect(harness.viewModel.status == .denied)

        await harness.fake.setStatus(.authorized)
        harness.model.scenePhase = .inactive
        await settleViewUpdate()
        harness.model.scenePhase = .active

        #expect(await eventuallyPumpingRunLoop { harness.viewModel.status == .authorized })
        #expect(await harness.fake.requestCount == 0)
    }

    // MARK: Hosting

    private final class ScenePhaseModel: ObservableObject {
        @Published var scenePhase: ScenePhase = .active
    }

    private struct Harness {
        let window: UIWindow
        let model: ScenePhaseModel
        let fake: DebugNotificationScheduling
        let viewModel: NotificationPermissionViewModel
    }

    private struct HostedSettings: View {
        @ObservedObject var model: ScenePhaseModel
        let viewModel: NotificationPermissionViewModel

        var body: some View {
            NavigationStack {
                SettingsScreen(notifications: viewModel)
            }
            .environment(\.scenePhase, model.scenePhase)
        }
    }

    /// Hosts a `SettingsScreen` and waits for its first status read.
    private static func host(status: NotificationAuthorizationStatus) async throws -> Harness {
        let fake = DebugNotificationScheduling(status: status)
        let viewModel = NotificationPermissionViewModel(notifications: fake) { _ in }
        let model = ScenePhaseModel()
        let controller = UIHostingController(
            rootView: HostedSettings(model: model, viewModel: viewModel)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        // `.task` loads the status when the screen appears.
        #expect(await eventuallyPumpingRunLoop { viewModel.status == status })
        return Harness(window: window, model: model, fake: fake, viewModel: viewModel)
    }
}
