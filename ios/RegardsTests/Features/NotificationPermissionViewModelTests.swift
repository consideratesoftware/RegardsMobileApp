import Foundation
import Testing
@testable import Regards

/// TF-06 slice 3 (§10 item 7). The Settings notifications row shows one of
/// three states and only prompts from `.notDetermined`. These tests drive the
/// view model with `DebugNotificationScheduling`, so none touches the real
/// notification center and none can raise the system permission alert.
///
/// Every test also pins what must not happen: a read never prompts, a decided
/// permission is never re-requested, and a failed or declined request never
/// invents a status.
@MainActor
struct NotificationPermissionViewModelTests {

    @Test(
        "Loading shows the system's current status and never prompts",
        arguments: [
            NotificationAuthorizationStatus.notDetermined,
            .denied,
            .authorized,
        ]
    )
    func loadReadsStatus(status: NotificationAuthorizationStatus) async {
        let fake = DebugNotificationScheduling(status: status)
        let viewModel = NotificationPermissionViewModel(notifications: fake)

        await viewModel.load()

        #expect(viewModel.status == status)
        #expect(await fake.requestCount == 0)
    }

    @Test("Before the first read the status is unknown and a request does not prompt")
    func requestBeforeFirstReadDoesNotPrompt() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .grant)
        let viewModel = NotificationPermissionViewModel(notifications: fake)
        #expect(viewModel.status == nil)

        await viewModel.requestAuthorization()

        #expect(viewModel.status == nil)
        #expect(await fake.requestCount == 0)
    }

    @Test("Requesting from not determined prompts once, then shows the new status")
    func requestFromNotDeterminedPromptsOnceThenRereads() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .grant)
        let viewModel = NotificationPermissionViewModel(notifications: fake)
        await viewModel.load()

        await viewModel.requestAuthorization()
        #expect(viewModel.status == .authorized)

        // A second tap is a no-op: the permission is decided now.
        await viewModel.requestAuthorization()
        #expect(viewModel.status == .authorized)
        #expect(await fake.requestCount == 1)
    }

    @Test("A declined request shows denied")
    func deniedResultShowsDenied() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .deny)
        let viewModel = NotificationPermissionViewModel(notifications: fake)
        await viewModel.load()

        await viewModel.requestAuthorization()

        #expect(viewModel.status == .denied)
        #expect(await fake.requestCount == 1)
    }

    @Test("A request that throws re-reads the status and leaves it undecided")
    func requestThrowRereadsStatus() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .fail)
        let viewModel = NotificationPermissionViewModel(notifications: fake)
        await viewModel.load()

        await viewModel.requestAuthorization()

        #expect(viewModel.status == .notDetermined)
        #expect(await fake.requestCount == 1)
    }

    @Test(
        "A request that throws after the user decided shows the decision",
        arguments: [NotificationAuthorizationStatus.denied, .authorized]
    )
    func requestThatThrowsAfterTheUserDecidedShowsTheDecision(decision: NotificationAuthorizationStatus) async {
        let viewModel = NotificationPermissionViewModel(notifications: DecidesThenThrows(decision: decision))
        await viewModel.load()
        #expect(viewModel.status == .notDetermined)

        await viewModel.requestAuthorization()

        #expect(viewModel.status == decision)
    }

    @Test(
        "A decided permission is never requested again",
        arguments: [NotificationAuthorizationStatus.denied, .authorized]
    )
    func noPromptWhenAlreadyDecided(status: NotificationAuthorizationStatus) async {
        let fake = DebugNotificationScheduling(status: status, requestOutcome: .grant)
        let viewModel = NotificationPermissionViewModel(notifications: fake)
        await viewModel.load()

        await viewModel.requestAuthorization()

        #expect(await fake.requestCount == 0)
        #expect(viewModel.status == status)
    }

    @Test("Refreshing picks up a change made in iOS Settings, without prompting")
    func refreshPicksUpIOSSettingsChange() async {
        let fake = DebugNotificationScheduling(status: .denied)
        let viewModel = NotificationPermissionViewModel(notifications: fake)
        await viewModel.load()
        #expect(viewModel.status == .denied)

        await fake.setStatus(.authorized)
        await viewModel.refresh()

        #expect(viewModel.status == .authorized)
        #expect(await fake.requestCount == 0)
    }

    /// `DebugNotificationScheduling.fail` throws without changing the status,
    /// which can't tell a view model that re-reads after a throw from one
    /// that doesn't. This one records the user's decision and then throws,
    /// as a prompt that is answered and then errors would.
    private actor DecidesThenThrows: NotificationScheduling {
        private var status = NotificationAuthorizationStatus.notDetermined
        private let decision: NotificationAuthorizationStatus

        init(decision: NotificationAuthorizationStatus) {
            self.decision = decision
        }

        nonisolated var actions: AsyncStream<NotificationAction> {
            AsyncStream { $0.finish() }
        }

        func requestAuthorization() async throws -> Bool {
            status = decision
            throw DebugNotificationScheduling.RequestFailed()
        }

        func authorizationStatus() async -> NotificationAuthorizationStatus { status }
    }
}
