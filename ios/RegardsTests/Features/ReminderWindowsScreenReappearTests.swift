import Observation
import SwiftUI
import Testing
@testable import Regards

/// The editor must keep unsaved edits when its screen goes away and comes
/// back (a popover closing, a push and pop). The screen's `.task` only loads
/// while the view model is still `.loading`; without that guard every
/// re-appearance would reload the stored window over the draft.
@MainActor
struct ReminderWindowsScreenReappearTests {

    private typealias Fixtures = ReminderWindowEditorFixtures

    @MainActor @Observable
    final class ShownModel {
        var shown = true
    }

    private struct Harness: View {
        let model: ShownModel
        let viewModel: ReminderWindowsViewModel

        var body: some View {
            if model.shown {
                ReminderWindowsScreen(viewModel: viewModel, announce: { _ in })
            } else {
                Text("Another screen")
            }
        }
    }

    /// Counts `fetchGlobal()` calls so a reload is visible even when it reads
    /// the same values.
    private struct CountingWindowRepository: ReminderWindowRepository {
        let wrapped: any ReminderWindowRepository
        let counter: CallCounter
        func fetchGlobal() async throws -> ReminderWindow {
            _ = await counter.next()
            return try await wrapped.fetchGlobal()
        }
        func saveGlobal(_ window: ReminderWindow) async throws { try await wrapped.saveGlobal(window) }
    }

    @Test("Unsaved edits survive the screen disappearing and appearing again, with no reload")
    func unsavedEditSurvivesReappearance() async throws {
        let world = try await Fixtures.makeWorld()
        let counter = CallCounter()
        let counting = CountingWindowRepository(wrapped: world.environment.window, counter: counter)
        let viewModel = Fixtures.editor(
            .global, contacts: world.environment.contacts, window: counting, recorder: Fixtures.SaveRecorder()
        )
        let model = ShownModel()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: Harness(model: model, viewModel: viewModel))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        #expect(await eventuallyPumpingRunLoop { viewModel.loadState == .loaded })
        // `next()` counts itself, so `next() - 1` is the number of reads before this call.
        let loadReads = await counter.next() - 1
        #expect(loadReads == 1)
        let edited = TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 10))
        viewModel.draft.allowedDays = .sunday
        viewModel.draft.allowedTimeRanges = [edited]
        let editedDraft = viewModel.draft

        model.shown = false
        window.layoutIfNeeded()
        await settleViewUpdate(iterations: 20)
        model.shown = true
        window.layoutIfNeeded()
        // A reload would run from the screen's `.task` on this re-mount.
        await settleViewUpdate(iterations: 40)

        #expect(viewModel.draft == editedDraft)
        #expect(viewModel.loadState == .loaded)
        // One more than before: the earlier `next()` above is the only extra call.
        #expect(await counter.next() - 1 == loadReads + 1, "no further fetchGlobal after the first load")
    }
}
