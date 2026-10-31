import Foundation

/// The onboarding steps (TF-11, ARCHITECTURE.md §10.8, §14 PR29), split from
/// `AppLaunchCoordinator.swift` to keep that file under the lint length
/// limit. The stored state (`onboardingStep`, `starterAccessIsLimited`) and
/// the completion write (`finishOnboarding()`) stay in the main file: stored
/// properties can't live in an extension, and the write sets `private(set)`
/// launch state.
///
/// Flow: `.concept` → `.contacts` (the existing pre-prompt and import) →
/// `.starter` (pick up to 3 people) → `onboardingCompletedAt`, written last.
/// Denying Contacts, or continuing after a failed import, completes from
/// `.contacts` and skips the starter step, since there is no one to pick.
extension AppLaunchCoordinator {
    enum OnboardingStep: Equatable {
        /// "Who have you been meaning to call?" A fresh install starts here.
        case concept
        /// The Contacts pre-prompt, the import, and its recovery messages.
        case contacts
        /// Pick up to 3 imported contacts to keep in touch with.
        case starter
    }

    /// "Get started" on the concept screen. No `onboardingActionGeneration`
    /// bump: nothing on the concept screen competes with launch work, and an
    /// authorized launch that is already importing should keep going.
    func showContactsStep() {
        guard phase == .onboarding, onboardingStep == .concept else { return }
        onboardingStep = .contacts
    }

    /// Called after a successful import, from launch or from the permission
    /// tap. Onboarding stays incomplete until the starter step finishes.
    func advanceToStarterStep() {
        onboardingStep = .starter
    }

    /// State for the Settings Contacts access row (R14's re-entry clause).
    /// Nil without a Contacts source (the DEBUG mock runtime), which hides the
    /// row. After a grant the row imports through the foreground reconcile.
    func makeContactsAccessViewModel() -> ContactsAccessViewModel? {
        guard let source = dependencies?.contactsSource else { return nil }
        return ContactsAccessViewModel(source: source, reconcile: { [weak self] in
            await self?.handleSceneActivation()
        })
    }
}
