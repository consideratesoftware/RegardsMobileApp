import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Regards

/// TF-06 slice 3 (§10 item 7). The Settings notifications row shows one of
/// three states and only prompts from `.notDetermined`. These tests drive the
/// view model with `DebugNotificationScheduling`, or with `ScriptedNotifications`
/// where they need a request that throws or a status read held back, so none
/// touches the real notification center and none can raise the system
/// permission alert.
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
        #expect(!viewModel.requestFailed)

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
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(ScriptedNotifications(requests: [.fails(deciding: decision)]), recorder)
        await viewModel.load()
        #expect(viewModel.status == .notDetermined)

        await viewModel.requestAuthorization()

        #expect(viewModel.status == decision)
        // The decision is what changed, so it is the only thing announced: no
        // "couldn't ask" error for a prompt the user did answer.
        #expect(recorder.messages == [decision == .authorized ? "Notifications on" : "Notifications off"])
        #expect(!viewModel.requestFailed)
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
}

extension NotificationPermissionViewModelTests {
    // MARK: Request error

    private static let errorMessage = NotificationPermissionViewModel.requestFailedMessage

    @Test("A request that throws shows the error and announces it")
    func requestThatThrowsShowsAndAnnouncesTheError() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .fail)
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(fake, recorder)
        await viewModel.load()
        #expect(!viewModel.requestFailed)

        await viewModel.requestAuthorization()

        #expect(viewModel.requestFailed)
        #expect(recorder.messages == [Self.errorMessage])
    }

    @Test("Each failed attempt announces the error again")
    func repeatedThrowsAnnounceEachTime() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .fail)
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(fake, recorder)
        await viewModel.load()

        await viewModel.requestAuthorization()
        await viewModel.requestAuthorization()

        #expect(viewModel.requestFailed)
        #expect(recorder.messages == [Self.errorMessage, Self.errorMessage])
    }

    @Test("A later request that succeeds clears the error")
    func laterSuccessfulRequestClearsTheError() async {
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(
            ScriptedNotifications(requests: [.fails(deciding: nil), .succeeds(deciding: .authorized)]), recorder
        )
        await viewModel.load()
        await viewModel.requestAuthorization()
        #expect(viewModel.requestFailed)

        await viewModel.requestAuthorization()

        #expect(!viewModel.requestFailed)
        #expect(viewModel.status == .authorized)
        #expect(recorder.messages == [Self.errorMessage, "Notifications on"])
    }

    @Test("A request that succeeds clears the error even when the status stays undecided")
    func successWithoutAStatusChangeClearsTheError() async {
        let viewModel = Self.viewModel(
            ScriptedNotifications(requests: [.fails(deciding: nil), .succeeds(deciding: nil)])
        )
        await viewModel.load()
        await viewModel.requestAuthorization()
        #expect(viewModel.requestFailed)

        await viewModel.requestAuthorization()

        #expect(!viewModel.requestFailed)
        #expect(viewModel.status == .notDetermined)
    }

    @Test("Re-reading an unchanged status keeps the error")
    func unchangedRefreshKeepsTheError() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .fail)
        let viewModel = Self.viewModel(fake)
        await viewModel.load()
        await viewModel.requestAuthorization()

        await viewModel.refresh()

        #expect(viewModel.requestFailed)
    }

    @Test("A real status change clears the error")
    func statusChangeClearsTheError() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .fail)
        let viewModel = Self.viewModel(fake)
        await viewModel.load()
        await viewModel.requestAuthorization()
        #expect(viewModel.requestFailed)

        await fake.setStatus(.denied)
        await viewModel.refresh()

        #expect(!viewModel.requestFailed)
        #expect(viewModel.status == .denied)
    }

    // MARK: Out-of-order reads

    /// Two status reads overlap and the older one finishes last, as the
    /// scene turning active during the prompt can make happen. The older
    /// answer is stale and must not overwrite the newer one, or the row would
    /// offer to prompt again for a permission already granted.
    @Test("A stale status read that finishes last does not overwrite a newer one")
    func staleStatusReadFinishingLastDoesNotRegressStatus() async throws {
        let fake = ScriptedNotifications(immediateReads: 1, heldReads: 2)
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(fake, recorder)
        await viewModel.load()
        #expect(viewModel.status == .notDetermined)
        await fake.setStatus(.authorized)

        let older = Task { await viewModel.refresh() }
        try #require(await NotificationActionHandlingTests.waitFor { await fake.heldReadCount == 1 })
        let newer = Task { await viewModel.refresh() }
        try #require(await NotificationActionHandlingTests.waitFor { await fake.heldReadCount == 2 })
        await fake.release(read: 1, as: .authorized)
        await newer.value
        await fake.release(read: 0, as: .notDetermined)
        await older.value

        #expect(viewModel.status == .authorized)
        #expect(recorder.messages == ["Notifications on"])
        await viewModel.requestAuthorization()
        #expect(await fake.requestCount == 0)
    }

    // MARK: Open iOS Settings

    @Test("Open iOS Settings opens the app's notification settings URL, once")
    func openNotificationSettingsOpensTheNotificationSettingsURL() async {
        let fake = DebugNotificationScheduling(status: .denied)
        let viewModel = Self.viewModel(fake)
        await viewModel.load()
        let opened = OpenedURLs()
        let action = OpenURLAction { url in
            opened.urls.append(url)
            return .handled
        }

        viewModel.openNotificationSettings(using: action)

        #expect(opened.urls.map(\.absoluteString) == [UIApplication.openNotificationSettingsURLString])
        #expect(await fake.requestCount == 0)
        #expect(viewModel.status == .denied)
    }

    // MARK: Overlapping calls

    /// Two refreshes in flight (the scene turning active while the request's
    /// own re-read runs) both see the change. Only the first to apply it
    /// speaks.
    @Test("Two overlapping refreshes after a change announce it once")
    func overlappingRefreshesAnnounceOnce() async {
        let fake = DebugNotificationScheduling(status: .denied)
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(fake, recorder)
        await viewModel.load()
        await fake.setStatus(.authorized)

        async let first: Void = viewModel.refresh()
        async let second: Void = viewModel.refresh()
        _ = await (first, second)

        #expect(viewModel.status == .authorized)
        #expect(recorder.messages == ["Notifications on"])
    }

    @Test("A request with an overlapping refresh announces the grant once")
    func requestWithOverlappingRefreshAnnouncesOnce() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .grant)
        let recorder = AnnouncementRecorder()
        let viewModel = Self.viewModel(fake, recorder)
        await viewModel.load()

        async let request: Void = viewModel.requestAuthorization()
        async let refresh: Void = viewModel.refresh()
        _ = await (request, refresh)

        #expect(viewModel.status == .authorized)
        #expect(recorder.messages == ["Notifications on"])
    }

    @Test("A second tap while the prompt is open does not prompt again")
    func doubleTapPromptsOnce() async {
        let fake = DebugNotificationScheduling(status: .notDetermined, requestOutcome: .grant)
        let viewModel = Self.viewModel(fake)
        await viewModel.load()

        async let first: Void = viewModel.requestAuthorization()
        async let second: Void = viewModel.requestAuthorization()
        _ = await (first, second)

        #expect(await fake.requestCount == 1)
        #expect(viewModel.status == .authorized)
    }
}

extension NotificationPermissionViewModelTests {
    // MARK: Helpers

    private final class OpenedURLs {
        var urls: [URL] = []
    }

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
}
