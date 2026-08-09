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

        for _ in 0..<20 where !recorder.isComplete {
            await Task.yield()
        }

        #expect(recorder.announcements == ["Contacts access isn't available."])
        #expect(recorder.focusAssignments == 1)
        window.isHidden = true
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
