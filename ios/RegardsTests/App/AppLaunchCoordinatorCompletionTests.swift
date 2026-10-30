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

    private static let han = SystemContact(
        identifier: "completion-han",
        givenName: "Han",
        familyName: "Solo",
        phoneNumbers: ["+1 555 010 2001"],
        emailAddresses: []
    )

    @Test("A failed completion save does not reconcile, so a contact added during the starter step waits")
    func failedFinishDoesNotReconcile() async throws {
        let base = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let profile = RetryingRecoveryProfileRepository(profile: Self.startedTrialProfile, failuresRemaining: 1)
        let environment = AppEnvironment(
            contacts: base.contacts, groups: base.groups, reminders: base.reminders,
            interactions: base.interactions, window: base.window, profile: profile
        )
        let source = MutableContactsSource(status: .authorized, contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        source.setContacts([Self.systemContact, Self.han])

        await launch.finishOnboarding()

        #expect(launch.onboardingCompletionPending)
        #expect(source.fetchCountValue() == 1, "Only the launch import has read the store.")
        #expect(try await environment.contacts.fetchAll().count == 1)
    }

    @Test("A Finish setup retry imports a contact added during the starter step without another event")
    func completionRetryImportsContactsAddedDuringStarter() async throws {
        let base = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let profile = RetryingRecoveryProfileRepository(profile: Self.startedTrialProfile, failuresRemaining: 1)
        let environment = AppEnvironment(
            contacts: base.contacts, groups: base.groups, reminders: base.reminders,
            interactions: base.interactions, window: base.window, profile: profile
        )
        let source = MutableContactsSource(status: .authorized, contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        // Han is added in the Contacts app while the starter step is on screen,
        // and the first Done fails to save.
        source.setContacts([Self.systemContact, Self.han])
        await launch.finishOnboarding()
        #expect(launch.onboardingCompletionPending)

        await launch.continueWithoutContacts()

        #expect(launch.phase == .ready)
        #expect(try await profile.fetch().onboardingCompletedAt == Self.now)
        let refs = try await environment.contacts.fetchAll().map(\.systemContactRef)
        #expect(Set(refs) == [Self.systemContact.identifier, Self.han.identifier])
        #expect(source.fetchCountValue() == 2, "The launch import plus one reconcile after the retry.")
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
