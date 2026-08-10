import Foundation
import Testing
@testable import Regards

/// R35 made a single row's write failure non-throwing (logged + counted in
/// `Result.failed`), so `runFirstLaunchImport()` no longer throws just
/// because a row failed. That's correct when the pass still imported
/// something — but before this fix, `requestContactsAndImport()` and
/// `importAuthorizedContacts()` both discarded the result entirely, so an
/// import where *every* row failed still fell through to
/// `completeOnboardingAfterImport`, silently finishing onboarding with an
/// empty All Contacts and no visible sign anything went wrong.
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
}
