import Foundation
import Testing
@testable import Regards

/// R35 made a single row's write failure non-throwing (logged + counted in
/// `Result.failed`), so `runFirstLaunchImport()` no longer throws just
/// because a row failed. That's correct when the pass still imported
/// something — but before this fix, `requestContactsAndImport()` and
/// `importAuthorizedContacts()` both discarded the result entirely, so an
/// import where *every* row failed still fell through to
/// the completion step (since TF-11 slice 3, the starter step and
/// `finishOnboarding()`), silently moving on with an empty All Contacts and
/// no visible sign anything went wrong.
@MainActor
struct AppLaunchCoordinatorImportFailureTests {
    let now = Date(timeIntervalSince1970: 1_785_600_000)

    private static let systemContact = SystemContact(
        identifier: "every-row-fails-contact",
        givenName: "Leia",
        familyName: "Organa",
        phoneNumbers: ["+1 555 010 2000"],
        emailAddresses: ["leia@example.com"]
    )

    /// Exercises `requestContactsAndImport()` — the permission-prompt-tap
    /// call site. Starts `.notDetermined` so `start()` waits for the
    /// explicit action instead of auto-importing, then the test drives the
    /// tap directly.
    @Test("An import where every row fails surfaces a visible failure instead of completing onboarding silently")
    func importWhereEveryRowFailsSurfacesFailure() async throws {
        let base = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let environment = AppEnvironment(
            contacts: FailingWriteContactRepository(failingIdentifiers: [Self.systemContact.identifier]),
            groups: base.groups,
            reminders: base.reminders,
            interactions: base.interactions,
            window: base.window,
            profile: base.profile
        )
        let source = ScriptedLaunchContactsSource(status: .notDetermined, contacts: [Self.systemContact])
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
                contactsSource: source,
                clock: { self.now }
            )
        )
        await launch.start()

        await launch.requestContactsAndImport()

        #expect(launch.phase == .onboarding)
        #expect(launch.statusMessage != nil)
        #expect(launch.canContinueWithoutContacts)
        #expect(!launch.isImporting)
        let profile = try await environment.profile.fetch()
        #expect(
            profile.onboardingCompletedAt == nil,
            "Onboarding must not complete silently when nothing was actually imported."
        )
    }

    /// Exercises `importAuthorizedContacts()` — the other call site,
    /// triggered automatically from `start()` when access is already
    /// `.authorized` at launch.
    @Test("An auto-import at launch where every row fails also surfaces a visible failure")
    func autoImportAtLaunchWhereEveryRowFailsSurfacesFailure() async throws {
        let base = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let environment = AppEnvironment(
            contacts: FailingWriteContactRepository(failingIdentifiers: [Self.systemContact.identifier]),
            groups: base.groups,
            reminders: base.reminders,
            interactions: base.interactions,
            window: base.window,
            profile: base.profile
        )
        let source = ScriptedLaunchContactsSource(status: .authorized, contacts: [Self.systemContact])
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
                contactsSource: source,
                clock: { self.now }
            )
        )

        await launch.start()

        #expect(launch.phase == .onboarding)
        #expect(launch.statusMessage != nil)
        #expect(launch.canContinueWithoutContacts)
        let profile = try await environment.profile.fetch()
        #expect(
            profile.onboardingCompletedAt == nil,
            "Onboarding must not complete silently when nothing was actually imported."
        )
    }

    /// The blocker case above is `failed > 0 && imported == 0`. This pins
    /// the other side of that condition: R35's per-row tolerance is meant to
    /// let a partially-successful import through, so `failed > 0 &&
    /// imported > 0` must complete onboarding normally, not get caught by
    /// `importEffectivelyFailed`'s guard as if the whole pass failed.
    @Test("An import where some rows fail but others succeed still reaches the starter step")
    func importWithPartialFailureStillReachesStarterStep() async throws {
        let okContact = SystemContact(
            identifier: "partial-failure-ok-contact",
            givenName: "Han",
            familyName: "Solo",
            phoneNumbers: ["+1 555 010 2001"],
            emailAddresses: []
        )
        let base = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let environment = AppEnvironment(
            contacts: FailingWriteContactRepository(failingIdentifiers: [Self.systemContact.identifier]),
            groups: base.groups,
            reminders: base.reminders,
            interactions: base.interactions,
            window: base.window,
            profile: base.profile
        )
        let source = ScriptedLaunchContactsSource(
            status: .authorized,
            contacts: [Self.systemContact, okContact]
        )
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
                contactsSource: source,
                clock: { self.now }
            )
        )

        await launch.start()

        // TF-11 slice 3: "completes onboarding" became "reaches the starter
        // step", because completion now waits for Done or Skip there.
        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .starter)
        #expect(launch.statusMessage == nil)
        #expect(!launch.canContinueWithoutContacts)
        let profile = try await environment.profile.fetch()
        #expect(profile.onboardingCompletedAt == nil)
        let stored = try await environment.contacts.fetchAll()
        #expect(stored.map(\.systemContactRef) == [okContact.identifier])
    }

    /// Round 10: `imported == 0 && failed > 0` alone isn't total failure
    /// either — a *resumed* import (most rows already imported from an
    /// earlier pass, one straggler row still failing) has `imported == 0`
    /// too, since there's nothing new to write, but it's not a failure at
    /// all: `runFirstLaunchImport` is correctly recognizing already-imported
    /// rows and skipping them. Requiring `skipped == 0` in
    /// `importEffectivelyFailed` is what tells this apart from a fresh
    /// total failure, which never skips anything.
    @Test("A resumed import that only re-encounters one already-failing row reaches the starter step")
    func resumedImportWithOnlyASkippedFailingRowReachesStarterStep() async throws {
        let alreadyImported = SystemContact(
            identifier: "already-imported-contact",
            givenName: "Chewbacca",
            familyName: "",
            phoneNumbers: [],
            emailAddresses: []
        )
        let base = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let environment = AppEnvironment(
            contacts: FailingWriteContactRepository(failingIdentifiers: [Self.systemContact.identifier]),
            groups: base.groups,
            reminders: base.reminders,
            interactions: base.interactions,
            window: base.window,
            profile: base.profile
        )
        // Simulates a prior pass that already imported "already-imported-
        // contact" successfully — a resumed pass should skip it (existing
        // ref), not treat it as new.
        try await environment.contacts.upsert(
            ContactsImporter.map(systemContact: alreadyImported, now: now)
        )
        let source = ScriptedLaunchContactsSource(
            status: .authorized,
            contacts: [alreadyImported, Self.systemContact]
        )
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
                contactsSource: source,
                clock: { self.now }
            )
        )

        await launch.start()

        // TF-11 slice 3: a resumed import is not a failure, so it reaches the
        // starter step instead of showing the failure copy.
        #expect(launch.phase == .onboarding)
        #expect(launch.onboardingStep == .starter)
        #expect(launch.statusMessage == nil)
        #expect(!launch.canContinueWithoutContacts)
        let profile = try await environment.profile.fetch()
        #expect(profile.onboardingCompletedAt == nil)
    }
}
