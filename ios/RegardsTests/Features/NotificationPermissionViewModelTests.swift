import Foundation
import Testing
@testable import Regards

/// TF-06 slice 3 (§10 item 7). The Settings notifications row shows one of
/// three states and only prompts from `.notDetermined`. These tests drive the
/// view model with `DebugNotificationScheduling`, so none touches the real
/// notification center and none can raise the system permission alert.
///
/// The view model speaks a status change through an injected closure. Tests
/// that are not about announcements pass a no-op, so the test host never
/// posts a real VoiceOver announcement.
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
        let viewModel = Self.viewModel(fake)

        await viewModel.load()

        #expect(viewModel.status == status)
        #expect(await fake.requestCount == 0)
    }

    @Test("Before the first read the status is unknown and a request does not prompt")
    func requestBeforeFirstReadDoesNotPrompt() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .grant)
        let viewModel = Self.viewModel(fake)
        #expect(viewModel.status == nil)

        await viewModel.requestAuthorization()

        #expect(viewModel.status == nil)
        #expect(await fake.requestCount == 0)
    }

    @Test("Requesting from not determined prompts once, then shows the new status")
    func requestFromNotDeterminedPromptsOnceThenRereads() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .grant)
        let viewModel = Self.viewModel(fake)
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
        let viewModel = Self.viewModel(fake)
        await viewModel.load()

        await viewModel.requestAuthorization()

        #expect(viewModel.status == .denied)
        #expect(await fake.requestCount == 1)
    }

    @Test("A request that throws re-reads the status and leaves it undecided")
    func requestThrowRereadsStatus() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .fail)
        let viewModel = Self.viewModel(fake)
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
        let viewModel = Self.viewModel(DecidesThenThrows(decision: decision))
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
        let viewModel = Self.viewModel(fake)
        await viewModel.load()

        await viewModel.requestAuthorization()

        #expect(await fake.requestCount == 0)
        #expect(viewModel.status == status)
    }

    @Test("Refreshing picks up a change made in iOS Settings, without prompting")
    func refreshPicksUpIOSSettingsChange() async {
        let fake = DebugNotificationScheduling(status: .denied)
        let viewModel = Self.viewModel(fake)
        await viewModel.load()
        #expect(viewModel.status == .denied)

        await fake.setStatus(.authorized)
        await viewModel.refresh()

        #expect(viewModel.status == .authorized)
        #expect(await fake.requestCount == 0)
    }

    // MARK: Announcements

    @Test(
        "The first read announces nothing, whatever the status",
        arguments: [
            NotificationAuthorizationStatus.notDetermined,
            .denied,
            .authorized,
        ]
    )
    func firstReadIsSilent(status: NotificationAuthorizationStatus) async {
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(DebugNotificationScheduling(status: status), recorder)

        await viewModel.load()

        #expect(recorder.messages.isEmpty)
    }

    @Test("A change to authorized in iOS Settings announces Notifications on")
    func changeToAuthorizedAnnouncesOn() async {
        let fake = DebugNotificationScheduling(status: .denied)
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(fake, recorder)
        await viewModel.load()

        await fake.setStatus(.authorized)
        await viewModel.refresh()

        #expect(recorder.messages == ["Notifications on"])
    }

    @Test("A change to denied in iOS Settings announces Notifications off")
    func changeToDeniedAnnouncesOff() async {
        let fake = DebugNotificationScheduling(status: .authorized)
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(fake, recorder)
        await viewModel.load()

        await fake.setStatus(.denied)
        await viewModel.refresh()

        #expect(recorder.messages == ["Notifications off"])
    }

    @Test(
        "Answering the prompt announces the result exactly once",
        arguments: [
            (DebugNotificationScheduling.RequestOutcome.grant, "Notifications on"),
            (DebugNotificationScheduling.RequestOutcome.deny, "Notifications off"),
        ]
    )
    func answeringThePromptAnnouncesOnce(
        outcome: DebugNotificationScheduling.RequestOutcome, expected: String
    ) async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: outcome)
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(fake, recorder)
        await viewModel.load()

        await viewModel.requestAuthorization()

        #expect(recorder.messages == [expected])
    }

    @Test("Re-reading an unchanged status announces nothing")
    func unchangedRereadIsSilent() async {
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(DebugNotificationScheduling(status: .authorized), recorder)
        await viewModel.load()

        await viewModel.refresh()
        await viewModel.refresh()

        #expect(recorder.messages.isEmpty)
    }

    @Test("A change back to not determined announces nothing")
    func changeToNotDeterminedIsSilent() async {
        let fake = DebugNotificationScheduling(status: .authorized)
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(fake, recorder)
        await viewModel.load()

        await fake.setStatus(.notDetermined)
        await viewModel.refresh()

        #expect(viewModel.status == .notDetermined)
        #expect(recorder.messages.isEmpty)
    }

    // MARK: Helpers

    /// Collects what the view model said, in order.
    private final class AnnouncementRecorder {
        var messages: [String] = []
    }

    /// With no recorder the announcements are dropped.
    private static func viewModel(
        _ notifications: any NotificationScheduling,
        _ recorder: AnnouncementRecorder? = nil
    ) -> NotificationPermissionViewModel {
        NotificationPermissionViewModel(notifications: notifications) { message in
            recorder?.messages.append(message)
        }
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
