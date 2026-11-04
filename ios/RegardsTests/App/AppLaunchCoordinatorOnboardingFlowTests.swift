import Foundation
import Testing
@testable import Regards

/// TF-11 slice 3 (ARCHITECTURE.md §10.8, R14): the onboarding steps in the
/// launch path. A fresh launch shows the concept screen, "Get started" shows
/// the Contacts pre-prompt, a successful import lands on the starter step with
/// onboarding still open, and only `finishOnboarding()` (the starter step's
/// Done or Skip) writes `onboardingCompletedAt`, as the last write. The step
/// is never stored: `start()` derives it from Contacts authorization and the
/// import result, so every relaunch test builds a second coordinator on the
/// same store.
///
/// An extension of `AppLaunchCoordinatorTests` to share its clock, coordinator
/// factory, and `ScriptedLaunchContactsSource`.
extension AppLaunchCoordinatorTests {
    private static let han = SystemContact(
        identifier: "flow-han",
        givenName: "Han",
        familyName: "Solo",
        phoneNumbers: ["+1 555 010 2001"],
        emailAddresses: []
    )
    private static let luke = SystemContact(
        identifier: "flow-luke",
        givenName: "Luke",
        familyName: "Skywalker",
        phoneNumbers: ["+1 555 010 2002"],
        emailAddresses: []
    )

    // MARK: Concept and Contacts steps

    @Test("A fresh launch starts at the concept screen and asks the system for nothing")
    func freshLaunchStartsAtConcept() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(status: .notDetermined)
        let launch = coordinator(environment: environment, source: source)

        await launch.start()

        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .concept)
        #expect(try await environment.profile.fetch().onboardingCompletedAt == nil)
        #expect(await source.counts() == .init(current: 1, requests: 0, fetches: 0))
    }

    @Test("Get started moves the concept screen to the Contacts pre-prompt without touching Contacts")
    func showContactsStepMovesConceptToContacts() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(status: .notDetermined)
        let launch = coordinator(environment: environment, source: source)
        await launch.start()

        launch.showContactsStep()

        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .contacts)
        #expect(await source.counts() == .init(current: 1, requests: 0, fetches: 0))
    }

    @Test("Get started does nothing once the flow is past the concept screen")
    func showContactsStepIsIgnoredPastConcept() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(status: .authorized, contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        #expect(launch.onboardingStep == .starter)

        launch.showContactsStep()

        #expect(launch.onboardingStep == .starter)
        #expect(launch.phase == .onboarding)
    }

    @Test("A denied launch lands on the Contacts step with recovery, skipping the concept screen")
    func deniedLaunchLandsOnContactsStep() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(status: .denied)
        let launch = coordinator(environment: environment, source: source)

        await launch.start()

        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .contacts)
        #expect(launch.canContinueWithoutContacts)
        #expect(launch.statusMessage != nil)
    }

    // MARK: Import reaches the starter step

    @Test("An authorized launch imports and waits at the starter step with onboarding still open")
    func authorizedImportAdvancesToStarterWithoutCompleting() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(status: .authorized, contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)

        await launch.start()

        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .starter)
        #expect(!launch.starterAccessIsLimited)
        #expect(!launch.isImporting)
        #expect(launch.statusMessage == nil)
        #expect(try await environment.profile.fetch().onboardingCompletedAt == nil)
        #expect(try await environment.contacts.fetchAll().map(\.systemContactRef)
            == [Self.systemContact.identifier])
        #expect(await source.counts() == .init(current: 2, requests: 0, fetches: 1))
    }

    @Test("Allowing Contacts from the pre-prompt imports and waits at the starter step")
    func permissionTapAdvancesToStarterWithoutCompleting() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(status: .notDetermined, contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        launch.showContactsStep()

        await launch.requestContactsAndImport()

        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .starter)
        #expect(!launch.starterAccessIsLimited)
        #expect(launch.statusMessage == nil)
        #expect(!launch.isImporting)
        #expect(try await environment.profile.fetch().onboardingCompletedAt == nil)
        #expect(try await environment.contacts.fetchAll().count == 1)
        #expect(await source.counts() == .init(current: 2, requests: 1, fetches: 1))
    }

    @Test("A failed import stays on the Contacts step so retry can resume")
    func failedImportStaysOnContactsStep() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(
            status: .notDetermined,
            contacts: [Self.systemContact],
            fetchFailuresRemaining: 1
        )
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        launch.showContactsStep()

        await launch.requestContactsAndImport()

        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .contacts)
        #expect(launch.statusMessage != nil)
    }

    // The test lives here because AppLaunchCoordinatorTests.swift is at the
    // 500-line lint limit; it uses that file's blocking source.
    @Test("A resumed launch holds the splash through the authorization read, then lands on the starter step")
    func resumingLaunchHoldsSplashThroughAuthorizationRead() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = BlockingAuthorizationContactsSource(contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)
        let start = Task { await launch.start() }
        await source.waitUntilCurrentAuthorizationStarts()

        // Mid-read the launch can't know yet whether this is a fresh install
        // or a resume, so it must not show the concept screen.
        #expect(launch.phase == .loading)

        await source.finishCurrentAuthorization()
        await start.value

        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .starter)
    }

    @Test("Finishing onboarding imports a contact added in the Contacts app during the starter step")
    func finishOnboardingImportsContactsAddedDuringTheStarterStep() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = MutableContactsSource(status: .authorized, contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        #expect(launch.onboardingStep == .starter)
        #expect(try await environment.contacts.fetchAll().count == 1)

        // Han is added in the Contacts app while the starter step is on screen.
        source.setContacts([Self.systemContact, Self.han])
        await launch.finishOnboarding()

        #expect(launch.phase == .ready)
        let refs = try await environment.contacts.fetchAll().map(\.systemContactRef)
        #expect(Set(refs) == [Self.systemContact.identifier, Self.han.identifier])
        #expect(source.fetchCountValue() == 2, "The import at launch plus one reconcile after Done.")
    }

    @Test("A starter picked in onboarding is scheduled when onboarding finishes, and a second full run is a no-op")
    func onboardingStarterIsScheduledWhenOnboardingFinishes() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(
            status: .authorized, contacts: [Self.systemContact, Self.han, Self.luke])
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        #expect(launch.onboardingStep == .starter)
        // The onboarding picker, as OnboardingFlowView builds it: no pass of its own.
        let picker = StarterContactsViewModel(contacts: environment.contacts, onSaved: { _ in })
        await picker.load()
        let leia = try #require(picker.contacts.first { $0.displayName == "Leia Organa" })
        let han = try #require(picker.contacts.first { $0.displayName == "Han Solo" })
        picker.toggle(leia.id)
        #expect(await picker.save())
        func pendingCadence(_ contact: Contact) async throws -> Bool {
            try await environment.reminders.fetchPending(forContact: contact.id).contains { $0.kind == .cadence }
        }
        #expect(try await pendingCadence(leia) == false, "Nothing is scheduled before onboarding finishes.")

        await launch.finishOnboarding()

        #expect(launch.phase == .ready)
        #expect(try await pendingCadence(leia), "Completion's full pass schedules the starter.")
        #expect(try await pendingCadence(han) == false)
        let pending = try await environment.reminders.fetchAllPending().sorted { $0.id.uuidString < $1.id.uuidString }
        try await #require(launch.runtime).scheduler.runFull()
        let afterFull = try await environment.reminders.fetchAllPending().sorted { $0.id.uuidString < $1.id.uuidString }
        #expect(afterFull == pending)
    }

    // The launch flips .loading to .onboarding only if nothing else decided
    // the phase while it read the authorization.
    @Test("Browsing without contacts during the authorization read is not undone when the read returns")
    func actionDuringAuthorizationReadIsNotUndone() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = BlockingAuthorizationContactsSource(contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)
        let start = Task { await launch.start() }
        await source.waitUntilCurrentAuthorizationStarts()

        await launch.continueWithoutContacts()
        #expect(launch.phase == .ready)
        await source.finishCurrentAuthorization()
        await start.value

        #expect(launch.phase == .ready)
        #expect(try await environment.profile.fetch().onboardingCompletedAt == now)
        #expect(try await environment.contacts.fetchAll().isEmpty, "The stale launch must not import afterwards.")
        #expect(await source.counts().fetches == 0)
    }

    // MARK: Finishing

    @Test("Finishing the starter step writes completion last and opens the tabs")
    func finishOnboardingCompletesAndOpensTabs() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(status: .authorized, contacts: [Self.systemContact])
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        #expect(try await environment.profile.fetch().onboardingCompletedAt == nil)

        await launch.finishOnboarding()

        #expect(launch.phase == .ready)
        #expect(launch.statusMessage == nil)
        #expect(!launch.onboardingCompletionPending)
        #expect(try await environment.profile.fetch().onboardingCompletedAt == now)
    }

    @Test("Finishing before the starter step is reached completes nothing", arguments: [
        ContactsAuthorizationStatus.notDetermined, .denied,
    ])
    func finishOnboardingIsIgnoredBeforeStarterStep(status: ContactsAuthorizationStatus) async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let launch = coordinator(environment: environment, source: ScriptedLaunchContactsSource(status: status))
        await launch.start()

        await launch.finishOnboarding()

        #expect(launch.phase == .onboarding)
        #expect(try await environment.profile.fetch().onboardingCompletedAt == nil)
    }

    @Test("Browsing without contacts completes from the Contacts step and never visits the starter step")
    func continueWithoutContactsSkipsStarterStep() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(status: .denied)
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        #expect(launch.onboardingStep == .contacts)

        await launch.continueWithoutContacts()

        #expect(launch.phase == .ready)
        #expect(launch.onboardingStep != .starter)
        #expect(try await environment.profile.fetch().onboardingCompletedAt == now)
        #expect(try await environment.contacts.fetchAll().isEmpty)
        #expect(await source.counts().fetches == 0)
    }

    // MARK: Relaunch

    @Test("Relaunching mid-starter resumes at the starter step with the saved picks and no duplicate rows")
    func relaunchMidStarterResumesWithSelections() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let everyone = [Self.systemContact, Self.han, Self.luke]
        let firstSource = ScriptedLaunchContactsSource(status: .authorized, contacts: everyone)
        let firstLaunch = coordinator(environment: environment, source: firstSource)
        await firstLaunch.start()
        #expect(firstLaunch.onboardingStep == .starter)
        let imported = try await environment.contacts.fetchAll()
        let leia = try #require(imported.first { $0.systemContactRef == Self.systemContact.identifier })
        let han = try #require(imported.first { $0.systemContactRef == Self.han.identifier })
        #expect(try await environment.contacts.updateTracking(id: leia.id, cadenceDays: 7))
        #expect(try await environment.contacts.updateTracking(id: han.id, cadenceDays: 30))

        // The app is killed here: nothing was completed, so a new process
        // starts over on the same store.
        let secondSource = ScriptedLaunchContactsSource(status: .authorized, contacts: everyone)
        let secondLaunch = coordinator(environment: environment, source: secondSource)
        await secondLaunch.start()

        #expect(secondLaunch.phase == .onboarding)
        #expect(secondLaunch.onboardingStep == .starter)
        #expect(try await environment.profile.fetch().onboardingCompletedAt == nil)
        #expect(try await environment.contacts.fetchAll().count == 3)
        #expect(await secondSource.counts() == .init(current: 2, requests: 0, fetches: 1))
        let picker = StarterContactsViewModel(contacts: environment.contacts, onSaved: { _ in })
        await picker.load()
        #expect(picker.selection == [leia.id: 7, han.id: 30])
    }

    // MARK: Limited access

    @Test("A fresh limited install offers only the shared people and says the list is limited")
    func limitedImportOffersSharedSubsetOnly() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        // The system shows Regards 2 of the user's 5 contacts; the other 3
        // never reach the source, so they never reach the store.
        let source = ScriptedLaunchContactsSource(status: .limited, contacts: [Self.han, Self.systemContact])
        let launch = coordinator(environment: environment, source: source)

        await launch.start()

        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .starter)
        #expect(launch.starterAccessIsLimited)
        let picker = StarterContactsViewModel(contacts: environment.contacts, onSaved: { _ in })
        await picker.load()
        #expect(picker.contacts.map(\.displayName) == ["Han Solo", "Leia Organa"])
    }

    // A pin, not a regression test: it passes on the code before the repair on
    // purpose. §7: a limited read never archives, so contacts imported under
    // full access stay active after a downgrade and the picker offers them
    // too, as All Contacts shows them.
    @Test("A relaunch after a downgrade to limited keeps the earlier imports on offer")
    func limitedRelaunchAfterDowngradeKeepsEarlierImports() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let everyone = [Self.systemContact, Self.han, Self.luke]
        let first = coordinator(
            environment: environment,
            source: ScriptedLaunchContactsSource(status: .authorized, contacts: everyone)
        )
        await first.start()
        #expect(first.onboardingStep == .starter)

        let second = coordinator(
            environment: environment,
            source: ScriptedLaunchContactsSource(status: .limited, contacts: [Self.han])
        )
        await second.start()

        #expect(second.onboardingStep == .starter)
        #expect(second.starterAccessIsLimited)
        let picker = StarterContactsViewModel(contacts: environment.contacts, onSaved: { _ in })
        await picker.load()
        #expect(picker.contacts.map(\.displayName) == ["Han Solo", "Leia Organa", "Luke Skywalker"])
    }

    @Test("Allowing limited access from the pre-prompt also marks the starter step limited")
    func limitedGrantFromPermissionTapMarksStarterLimited() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(
            status: .notDetermined,
            contacts: [Self.systemContact],
            requestResult: .limited
        )
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        launch.showContactsStep()

        await launch.requestContactsAndImport()

        #expect(launch.onboardingStep == .starter)
        #expect(launch.starterAccessIsLimited)
    }

    @Test("Sharing no one under limited access still reaches the starter step and can finish")
    func limitedWithZeroSharedCanFinish() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(status: .limited, contacts: [])
        let launch = coordinator(environment: environment, source: source)

        await launch.start()

        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .starter)
        #expect(launch.starterAccessIsLimited)
        #expect(launch.statusMessage == nil)
        let picker = StarterContactsViewModel(contacts: environment.contacts, onSaved: { _ in })
        await picker.load()
        #expect(picker.loadState == .loaded)
        #expect(picker.contacts.isEmpty)

        await launch.finishOnboarding()

        #expect(launch.phase == .ready)
        #expect(try await environment.profile.fetch().onboardingCompletedAt == now)
    }
}
