import SwiftUI
import Testing
import UIKit
@testable import Regards

@MainActor
struct OnboardingAccessibilityEffectsTests {
    @Test("Initial denial announces recovery and assigns accessibility focus")
    func initialDenialTriggersRecoveryEffects() async {
        let recorder = RecoveryEffectsRecorder()
        var screen = OnboardingScreen(
            statusMessage: "Contacts access isn't available.",
            canContinueWithoutContacts: true,
            onContinueWithoutContacts: {}
        )
        screen.accessibilityEffects = OnboardingAccessibilityEffects(
            announce: { recorder.announcements.append($0) },
            didFocusRecovery: { recorder.focusAssignments += 1 }
        )

        let host = UIHostingController(rootView: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()

        #expect(await eventually { recorder.isComplete })

        #expect(recorder.announcements == ["Contacts access isn't available."])
        #expect(recorder.focusAssignments == 1)
        window.isHidden = true
    }

    @Test("Newer recovery statuses cancel pending announcement and focus effects")
    func newerStatusCancelsStaleEffects() async {
        let recorder = RecoveryEffectsRecorder()
        let suspension = RecoveryEffectsSuspension()
        let model = RecoveryStatusModel(message: "First failure")
        let effects = OnboardingAccessibilityEffects(
            announce: { recorder.announcements.append($0) },
            didFocusRecovery: { recorder.focusAssignments += 1 },
            yieldControl: { await suspension.pause() }
        )
        let host = UIHostingController(
            rootView: RecoveryStatusHarness(model: model, effects: effects)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()

        #expect(await eventually { suspension.arrivalCount == 1 })
        model.message = "Second failure"
        #expect(await eventually { suspension.arrivalCount == 2 })

        suspension.resumeNext()
        await Task.yield()
        #expect(recorder.announcements.isEmpty)
        #expect(recorder.focusAssignments == 0)

        suspension.resumeNext()
        #expect(await eventually { suspension.arrivalCount == 3 })
        #expect(recorder.announcements == ["Second failure"])
        #expect(recorder.focusAssignments == 0)

        model.message = "Third failure"
        #expect(await eventually { suspension.arrivalCount == 4 })

        suspension.resumeNext()
        await Task.yield()
        #expect(recorder.focusAssignments == 0)

        suspension.resumeNext()
        #expect(await eventually { suspension.arrivalCount == 5 })
        #expect(recorder.announcements == ["Second failure", "Third failure"])

        suspension.resumeNext()
        #expect(await eventually { recorder.focusAssignments == 1 })
        #expect(recorder.announcements == ["Second failure", "Third failure"])
        window.isHidden = true
    }

    @Test("A repeated launch failure cancels stale announcement and focus effects")
    func repeatedLaunchFailureCancelsStaleEffects() async {
        let recorder = RecoveryEffectsRecorder()
        let suspension = RecoveryEffectsSuspension()
        let runtimeFactory = RepeatedLaunchFailureRuntimeFactory()
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await runtimeFactory.makeRuntime() },
                contactsSource: UnusedLaunchFailureContactsSource(),
                clock: { Date(timeIntervalSince1970: 1_785_600_000) }
            )
        )
        var root = RootView(launch: launch)
        root.launchFailureAccessibilityEffects = LaunchFailureAccessibilityEffects(
            announce: { recorder.announcements.append($0) },
            didFocusRetry: { recorder.focusAssignments += 1 },
            yieldControl: { await suspension.pause() }
        )
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()

        #expect(await eventually { suspension.arrivalCount == 1 })
        await launch.retry()
        #expect(await eventually { suspension.arrivalCount == 2 })

        suspension.resumeNext()
        await Task.yield()
        #expect(recorder.announcements.isEmpty)
        #expect(recorder.focusAssignments == 0)

        suspension.resumeNext()
        #expect(await eventually { suspension.arrivalCount == 3 })
        #expect(recorder.announcements == ["Regards couldn't open its local data. Try again."])
        #expect(recorder.focusAssignments == 0)

        suspension.resumeNext()
        #expect(await eventually { recorder.focusAssignments == 1 })
        window.isHidden = true
    }
}

@MainActor
private final class RecoveryStatusModel: ObservableObject {
    @Published var message: String?

    init(message: String?) {
        self.message = message
    }
}

private struct RecoveryStatusHarness: View {
    @ObservedObject var model: RecoveryStatusModel
    let effects: OnboardingAccessibilityEffects

    var body: some View {
        var screen = OnboardingScreen(
            statusMessage: model.message,
            canContinueWithoutContacts: true,
            onContinueWithoutContacts: {}
        )
        screen.accessibilityEffects = effects
        return screen
    }
}

@MainActor
private final class RecoveryEffectsSuspension {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivalCount = 0

    func pause() async {
        arrivalCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        continuations.removeFirst().resume()
    }
}

@MainActor
private final class RecoveryEffectsRecorder {
    var announcements: [String] = []
    var focusAssignments = 0

    var isComplete: Bool {
        announcements.count == 1 && focusAssignments == 1
    }
}

private enum RepeatedLaunchFailure: Error {
    case openFailed
}

private actor RepeatedLaunchFailureRuntimeFactory {
    func makeRuntime() throws -> AppRuntime {
        throw RepeatedLaunchFailure.openFailed
    }
}

private struct UnusedLaunchFailureContactsSource: ContactsSource {
    func currentAuthorization() async -> ContactsAuthorizationStatus { .notDetermined }
    func requestAccess() async throws -> ContactsAuthorizationStatus { .notDetermined }
    func fetchAllContacts() async throws -> [SystemContact] { [] }
}
