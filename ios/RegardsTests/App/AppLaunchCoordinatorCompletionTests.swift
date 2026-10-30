import Foundation
import Testing
@testable import Regards

/// TF-11 slice 3: the completion write at the end of the starter step. Shares
/// the profile fakes and helpers in `AppLaunchCoordinatorRecoveryTests.swift`.
extension AppLaunchCoordinatorRecoveryTests {
    @Test("A failed completion save shows Finish setup, keeps the starter picks, and retry completes")
    func completionSaveFailureShowsFinishSetupAndRetryCompletes() async throws {
        let profile = RetryingRecoveryProfileRepository(
            profile: Self.startedTrialProfile,
            failuresRemaining: 1
        )
        let source = RecoveryContactsSource(status: .authorized, contacts: [Self.systemContact])
        let runtime = runtime(profile: profile)
        let launch = coordinator(runtime: runtime, source: source)
        await launch.start()
        let leia = try #require(try await runtime.environment.contacts.fetchAll().first {
            $0.systemContactRef == Self.systemContact.identifier
        })
        #expect(try await runtime.environment.contacts.updateTracking(id: leia.id, cadenceDays: 14))

        await launch.finishOnboarding()

        // The screen swaps the starter step for the Contacts step, whose
        // button reads "Finish setup" while completion is pending.
        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .contacts)
        #expect(launch.onboardingCompletionPending)
        #expect(launch.statusMessage == Self.finishSetupFailureMessage)
        #expect(launch.canContinueWithoutContacts)
        #expect(!launch.isImporting)
        #expect(try await profile.fetch().onboardingCompletedAt == nil)

        await launch.continueWithoutContacts()

        #expect(launch.phase == .ready)
        #expect(!launch.onboardingCompletionPending)
        #expect(launch.statusMessage == nil)
        #expect(try await profile.fetch().onboardingCompletedAt == Self.now)
        let kept = try await runtime.environment.contacts.fetchAll().first { $0.id == leia.id }
        #expect(kept?.tracked == true)
        #expect(kept?.cadenceDays == 14)
    }

    @Test("Done after onboarding is already complete writes nothing")
    func finishAfterReadyWritesNothing() async throws {
        let profile = RetryingRecoveryProfileRepository(profile: Self.startedTrialProfile, failuresRemaining: 0)
        let source = RecoveryContactsSource(status: .authorized, contacts: [Self.systemContact])
        let launch = coordinator(runtime: runtime(profile: profile), source: source)
        await launch.start()
        await launch.finishOnboarding()
        #expect(launch.phase == .ready)
        #expect(await profile.saveCount() == 1)

        await launch.finishOnboarding()

        #expect(launch.phase == .ready)
        #expect(await profile.saveCount() == 1)
        #expect(try await profile.fetch().onboardingCompletedAt == Self.now)
    }

    @Test("Double-tapping Done starts one completion save", .timeLimit(.minutes(1)))
    func doubleFinishTapStartsOneSave() async throws {
        let profile = BlockingRecoveryProfileRepository(profile: Self.startedTrialProfile)
        let source = RecoveryContactsSource(status: .authorized, contacts: [Self.systemContact])
        let launch = coordinator(runtime: runtime(profile: profile), source: source)
        await launch.start()
        #expect(launch.onboardingStep == .starter)

        let firstTap = Task { await launch.finishOnboarding() }
        await profile.waitUntilSaveStarts()
        await launch.finishOnboarding()
        // The second tap returned while the first save is still held, and
        // started no save of its own.
        #expect(await profile.saveCount() == 1)
        await profile.finishSave()
        await firstTap.value

        #expect(launch.phase == .ready)
        #expect(await profile.saveCount() == 1)
    }
}
