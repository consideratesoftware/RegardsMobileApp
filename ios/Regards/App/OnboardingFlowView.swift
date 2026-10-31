import SwiftUI

/// The onboarding steps under `RootView` (TF-11, ARCHITECTURE.md §10.8). The
/// step comes from `AppLaunchCoordinator.onboardingStep`, which `start()`
/// derives again on every launch, so a relaunch resumes where the user left
/// off. Split from RegardsApp.swift to keep that file under the lint length
/// limit.
struct OnboardingFlowView: View {
    let launch: AppLaunchCoordinator
    let onWhyWeAsk: () -> Void

    var body: some View {
        switch launch.onboardingStep {
        case .concept:
            OnboardingConceptScreen(onContinue: { launch.showContactsStep() })
                .transition(.opacity)
        case .contacts:
            OnboardingScreen(
                showsPermissionAction: !launch.onboardingCompletionPending,
                isBusy: launch.isImporting,
                statusMessage: launch.statusMessage,
                canContinueWithoutContacts: launch.canContinueWithoutContacts,
                continueActionTitle: launch.onboardingCompletionPending
                    ? "Finish setup"
                    : "Continue without contacts",
                onAllow: {
                    Task { await launch.requestContactsAndImport() }
                },
                onContinueWithoutContacts: {
                    Task { await launch.continueWithoutContacts() }
                },
                onWhyWeAsk: onWhyWeAsk
            )
            .transition(.opacity)
        case .starter:
            if let runtime = launch.runtime {
                // Its own stack: the screen's search field needs one.
                NavigationStack {
                    StarterContactsScreen(
                        viewModel: StarterContactsViewModel(
                            contacts: runtime.environment.contacts,
                            // No pass here: completion's `runFull()` schedules the starters.
                            onSaved: { _ in }
                        ),
                        showsSkip: true,
                        showsLimitedAccessNote: launch.starterAccessIsLimited,
                        onFinish: { Task { await launch.finishOnboarding() } }
                    )
                }
                .transition(.opacity)
            } else {
                // Unreachable: `.starter` follows an import, which needs the
                // runtime. The splash beats an empty screen if that changes.
                SplashView()
            }
        }
    }
}
