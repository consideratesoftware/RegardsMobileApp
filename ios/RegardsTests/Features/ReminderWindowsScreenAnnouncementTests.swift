import SwiftUI
import Testing
@testable import Regards

/// A refused save is announced to VoiceOver through the screen's injectable
/// `announce:` closure, following `AllContactsCorruptionAnnouncementTests`:
/// host the real screen, drive the view model, assert on a recorder. The
/// announcement keys off `failureCount`, so a second identical refusal is
/// announced again and a successful save announces nothing.
@MainActor
struct ReminderWindowsScreenAnnouncementTests {

    private typealias Fixtures = ReminderWindowEditorFixtures

    @MainActor
    private final class Recorder {
        private(set) var announcements: [String] = []
        func record(_ message: String) { announcements.append(message) }
    }

    private static func host(
        _ viewModel: ReminderWindowsViewModel,
        recorder: Recorder
    ) async -> UIWindow {
        let screen = ReminderWindowsScreen(viewModel: viewModel, announce: { recorder.record($0) })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: screen)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        // The screen loads the view model from its own `.task`.
        _ = await eventuallyPumpingRunLoop { viewModel.loadState == .loaded }
        return window
    }

    @Test("A refused save announces its message once, and an identical second refusal announces again")
    func refusedSaveAnnouncesEachTime() async throws {
        let world = try await Fixtures.makeWorld()
        let viewModel = Fixtures.editor(.global, world: world, recorder: Fixtures.SaveRecorder())
        let recorder = Recorder()
        let window = await Self.host(viewModel, recorder: recorder)
        defer { window.isHidden = true }
        #expect(viewModel.loadState == .loaded)
        viewModel.draft.allowedDays = []

        #expect(!(await viewModel.save()))
        #expect(await eventuallyPumpingRunLoop { recorder.announcements.count == 1 })
        #expect(recorder.announcements == ["Pick at least one day."])

        #expect(!(await viewModel.save()))
        #expect(await eventuallyPumpingRunLoop { recorder.announcements.count == 2 })
        #expect(recorder.announcements == ["Pick at least one day.", "Pick at least one day."])
    }

    @Test("A successful save announces nothing")
    func successfulSaveAnnouncesNothing() async throws {
        let world = try await Fixtures.makeWorld()
        let viewModel = Fixtures.editor(.global, world: world, recorder: Fixtures.SaveRecorder())
        let recorder = Recorder()
        let window = await Self.host(viewModel, recorder: recorder)
        defer { window.isHidden = true }
        #expect(viewModel.loadState == .loaded)
        viewModel.draft.allowedDays = .saturday

        #expect(await viewModel.save())
        // Give a late announcement time to land before asserting there is none.
        await settleViewUpdate(iterations: 20)

        #expect(recorder.announcements.isEmpty)
    }

    @Test("A save whose pass fails announces the not-rescheduled sentence")
    func notRescheduledSaveAnnouncesTheSentence() async throws {
        let world = try await Fixtures.makeWorld()
        let saveRecorder = Fixtures.SaveRecorder()
        saveRecorder.rescheduled = false
        let viewModel = Fixtures.editor(.global, world: world, recorder: saveRecorder)
        let recorder = Recorder()
        let window = await Self.host(viewModel, recorder: recorder)
        defer { window.isHidden = true }
        #expect(viewModel.loadState == .loaded)
        viewModel.draft.allowedDays = .saturday

        #expect(!(await viewModel.save()))

        #expect(await eventuallyPumpingRunLoop { recorder.announcements.count == 1 })
        #expect(recorder.announcements == [ReminderWindowsViewModel.notRescheduledMessage])
    }
}
