import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Regards

/// TF-11 slice 4 (§10.8, R14's re-entry clause). The Settings Contacts access
/// row has 3 behaviors, one per group of `ContactsAuthorizationStatus`:
///
/// - `.denied` offers iOS Settings and never prompts.
/// - `.restricted`, `.authorized` and `.limited` are status text: nothing to
///   tap. Restricted is parental controls or device management, which iOS
///   Settings can't lift, so a button there would lead nowhere.
/// - `.notDetermined` requests access, then runs the coordinator's reconcile
///   entry, but only when access was granted.
///
/// These drive `ContactsAccessViewModel` with `MutableContactsSource`, so no
/// test can raise the system permission alert. A hosted SwiftUI button exposes
/// no accessibility elements to a unit test, so the row's own shape (button or
/// plain text, label, id) is covered by the UI tests
/// `testSettingsContactsDeniedOffersIOSSettings` and
/// `testSettingsContactsAuthorizedIsStatusOnly`.
@MainActor
struct SettingsContactsRowTests {

    // MARK: Denied

    @Test("Denied shows its status and opens iOS Settings once, never the prompt")
    func deniedOpensIOSSettings() async {
        let source = MutableContactsSource(status: .denied)
        let probe = Probe()
        let viewModel = Self.viewModel(source, probe)
        await viewModel.load()
        let opened = OpenedURLs()

        viewModel.openContactsSettings(using: OpenURLAction { url in
            opened.urls.append(url)
            return .handled
        })
        await viewModel.requestAccess()

        #expect(viewModel.status == .denied)
        #expect(opened.urls.map(\.absoluteString) == [UIApplication.openSettingsURLString])
        #expect(source.requestCountValue() == 0)
        #expect(probe.reconcileCount == 0)
    }

    // MARK: Restricted

    /// Parental controls or device management: iOS Settings can't lift the
    /// restriction, so the row is status text with no button. Nothing prompts
    /// or imports. The absence of a button is the row's shape, which a unit
    /// test can't see; this pins the view model side.
    @Test("Restricted shows its status; a request neither prompts nor imports")
    func restrictedIsStatusOnly() async {
        let source = MutableContactsSource(status: .restricted)
        let probe = Probe()
        let viewModel = Self.viewModel(source, probe)
        await viewModel.load()

        await viewModel.requestAccess()

        #expect(viewModel.status == .restricted)
        #expect(!viewModel.requestFailed)
        #expect(source.requestCountValue() == 0)
        #expect(probe.reconcileCount == 0)
    }

    // MARK: Authorized and limited

    @Test(
        "Authorized and limited are status only: a request does nothing",
        arguments: [ContactsAuthorizationStatus.authorized, .limited]
    )
    func authorizedAndLimitedHaveNothingToRequest(status: ContactsAuthorizationStatus) async {
        let source = MutableContactsSource(status: status)
        let probe = Probe()
        let viewModel = Self.viewModel(source, probe)
        await viewModel.load()

        await viewModel.requestAccess()

        #expect(viewModel.status == status)
        #expect(!viewModel.requestFailed)
        #expect(source.requestCountValue() == 0)
        #expect(probe.reconcileCount == 0)
    }

    // MARK: Not determined

    @Test(
        "Not determined requests access once, then reconciles once, after the new status is shown",
        arguments: [ContactsAuthorizationStatus.authorized, .limited]
    )
    func notDeterminedRequestsThenReconciles(granted: ContactsAuthorizationStatus) async {
        let source = MutableContactsSource(status: .notDetermined)
        source.setRequestOutcome(.success(granted))
        let probe = Probe()
        let viewModel = Self.viewModel(source, probe)
        probe.statusWhenReconciled = { viewModel.status }
        await viewModel.load()
        #expect(viewModel.status == .notDetermined)

        await viewModel.requestAccess()

        #expect(source.requestCountValue() == 1)
        #expect(probe.reconcileCount == 1)
        #expect(probe.statusesWhenReconciled == [granted])
        #expect(viewModel.status == granted)
        #expect(!viewModel.requestFailed)

        // The row is status text now, so a second tap has nothing to do.
        await viewModel.requestAccess()
        #expect(source.requestCountValue() == 1)
        #expect(probe.reconcileCount == 1)
    }

    @Test("A declined request shows denied and imports nothing")
    func declinedRequestDoesNotReconcile() async {
        let source = MutableContactsSource(status: .notDetermined)
        source.setRequestOutcome(.success(.denied))
        let probe = Probe()
        let viewModel = Self.viewModel(source, probe)
        await viewModel.load()

        await viewModel.requestAccess()

        #expect(viewModel.status == .denied)
        #expect(source.requestCountValue() == 1)
        #expect(probe.reconcileCount == 0)
        #expect(!viewModel.requestFailed)
    }

    @Test("A request that throws leaves the row retryable, shows the error, and imports nothing")
    func throwingRequestShowsErrorAndDoesNotReconcile() async {
        let source = MutableContactsSource(status: .notDetermined)
        source.setRequestOutcome(.failure(RequestFailed()))
        let probe = Probe()
        let viewModel = Self.viewModel(source, probe)
        await viewModel.load()

        await viewModel.requestAccess()

        #expect(viewModel.status == .notDetermined)
        #expect(viewModel.requestFailed)
        #expect(probe.reconcileCount == 0)
        #expect(probe.messages == [ContactsAccessViewModel.requestFailedMessage])

        // The user can try again, and a grant clears the error.
        source.setRequestOutcome(.success(.authorized))
        await viewModel.requestAccess()
        #expect(viewModel.status == .authorized)
        #expect(!viewModel.requestFailed)
        #expect(source.requestCountValue() == 2)
        #expect(probe.reconcileCount == 1)
    }

    @Test("A request before the first status read does not prompt")
    func requestBeforeFirstReadDoesNotPrompt() async {
        let source = MutableContactsSource(status: .notDetermined)
        let probe = Probe()
        let viewModel = Self.viewModel(source, probe)
        #expect(viewModel.status == nil)

        await viewModel.requestAccess()

        #expect(viewModel.status == nil)
        #expect(source.requestCountValue() == 0)
        #expect(probe.reconcileCount == 0)
    }

    @Test("A second tap while the prompt is open does not prompt or import twice")
    func doubleTapRequestsOnce() async {
        let source = MutableContactsSource(status: .notDetermined)
        source.setRequestOutcome(.success(.authorized))
        let probe = Probe()
        let viewModel = Self.viewModel(source, probe)
        await viewModel.load()

        async let first: Void = viewModel.requestAccess()
        async let second: Void = viewModel.requestAccess()
        _ = await (first, second)

        #expect(source.requestCountValue() == 1)
        #expect(probe.reconcileCount == 1)
    }

    // MARK: Announcements

    @Test("A change made in iOS Settings is announced once, and the first read is silent")
    func statusChangesAreAnnounced() async {
        let source = MutableContactsSource(status: .denied)
        let probe = Probe()
        let viewModel = Self.viewModel(source, probe)
        await viewModel.load()
        #expect(probe.messages.isEmpty)

        await viewModel.refresh()
        #expect(probe.messages.isEmpty)

        source.setStatus(.authorized)
        await viewModel.refresh()
        await viewModel.refresh()
        source.setStatus(.limited)
        await viewModel.refresh()
        source.setStatus(.denied)
        await viewModel.refresh()
        source.setStatus(.restricted)
        await viewModel.refresh()

        #expect(probe.messages == [
            "Contacts access on",
            "Contacts access limited",
            "Contacts access off",
            "Contacts access restricted",
        ])
        // Coming back from iOS Settings only re-reads. Importing is the
        // foreground reconcile's job, so this path never calls it.
        #expect(probe.reconcileCount == 0)
        #expect(source.requestCountValue() == 0)
    }

    // MARK: Helpers

    private struct RequestFailed: Error {}

    private final class OpenedURLs {
        var urls: [URL] = []

    }

    /// Collects what the view model said and how often it reconciled.
    @MainActor
    private final class Probe {
        var messages: [String] = []
        var reconcileCount = 0
        var statusesWhenReconciled: [ContactsAuthorizationStatus?] = []
        var statusWhenReconciled: (@MainActor () -> ContactsAuthorizationStatus?)?
    }

    private static func viewModel(_ source: MutableContactsSource, _ probe: Probe) -> ContactsAccessViewModel {
        ContactsAccessViewModel(
            source: source,
            reconcile: {
                probe.reconcileCount += 1
                probe.statusesWhenReconciled.append(probe.statusWhenReconciled?())
            },
            announce: { probe.messages.append($0) }
        )
    }
}

/// The coordinator side of the same row: the view model comes from
/// `AppLaunchCoordinator.makeContactsAccessViewModel()` and its reconcile
/// closure is the coordinator's foreground reconcile, so a grant from Settings
/// really imports (R14's re-entry clause).
@MainActor
struct SettingsContactsReentryCoordinatorTests {
    let now = Date(timeIntervalSince1970: 1_785_600_000)

    private static let leia = SystemContact(
        identifier: "reentry-leia",
        givenName: "Leia",
        familyName: "Organa",
        phoneNumbers: ["+1 555 010 2000"],
        emailAddresses: ["leia@example.com"]
    )

    @Test("Allowing Contacts from Settings imports the contacts through the coordinator")
    func grantFromSettingsImports() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await completeOnboarding(environment)
        let source = MutableContactsSource(status: .notDetermined, contacts: [Self.leia])
        source.setRequestOutcome(.success(.authorized))
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        #expect(launch.phase == .ready)
        let passesBefore = launch.reconciliationCount
        #expect(try await environment.contacts.fetchAll().isEmpty)
        let viewModel = try #require(launch.makeContactsAccessViewModel())
        await viewModel.load()
        #expect(viewModel.status == .notDetermined)

        await viewModel.requestAccess()

        #expect(viewModel.status == .authorized)
        #expect(launch.reconciliationCount == passesBefore + 1)
        let imported = try await environment.contacts.fetchAll()
        #expect(imported.map(\.displayName) == ["Leia Organa"])
        #expect(imported.first?.tracked == false)
    }

    @Test("A declined prompt from Settings runs no reconcile pass")
    func declineFromSettingsDoesNotReconcile() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await completeOnboarding(environment)
        let source = MutableContactsSource(status: .notDetermined, contacts: [Self.leia])
        source.setRequestOutcome(.success(.denied))
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        let passesBefore = launch.reconciliationCount
        let viewModel = try #require(launch.makeContactsAccessViewModel())
        await viewModel.load()

        await viewModel.requestAccess()

        #expect(viewModel.status == .denied)
        #expect(launch.reconciliationCount == passesBefore)
        #expect(try await environment.contacts.fetchAll().isEmpty)
    }

    /// Pin: the denied row sends the user to iOS Settings and promises that
    /// Regards imports on return. That import is the existing foreground
    /// reconcile, which passes on the code before this slice.
    @Test("Granting access in iOS Settings imports on the next foreground")
    func returningFromIOSSettingsImports() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await completeOnboarding(environment)
        let source = MutableContactsSource(status: .denied, contacts: [])
        let launch = coordinator(environment: environment, source: source)
        await launch.start()
        #expect(try await environment.contacts.fetchAll().isEmpty)
        let viewModel = try #require(launch.makeContactsAccessViewModel())
        await viewModel.load()
        #expect(viewModel.status == .denied)

        source.setStatus(.authorized)
        source.setContacts([Self.leia])
        await launch.handleSceneActivation()
        await viewModel.refresh()

        #expect(viewModel.status == .authorized)
        #expect(try await environment.contacts.fetchAll().map(\.displayName) == ["Leia Organa"])
    }

    @Test("A launch with no Contacts source has no Contacts access row")
    func mockRuntimeHasNoContactsAccess() {
        let launch = AppLaunchCoordinator(mockRuntime: .makeMock(), notifications: nil)

        #expect(launch.makeContactsAccessViewModel() == nil)
    }

    // MARK: Helpers

    private func completeOnboarding(_ environment: AppEnvironment) async throws {
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
    }

    private func coordinator(environment: AppEnvironment, source: any ContactsSource) -> AppLaunchCoordinator {
        let now = self.now
        return AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await AppRuntime.makeProduction(environment: environment) },
                contactsSource: source,
                clock: { now }
            )
        )
    }
}
