import SwiftUI
import Testing
@testable import Regards

/// Done can hold "Saving…" through the writes and, from Settings, the
/// reschedule, with nothing else spoken. The screen posts one "Saving" through
/// its injectable `announce:` when a save that will write starts, following
/// `ReminderWindowsScreenAnnouncementTests`: host the real screen, drive the
/// view model, assert on a recorder. The recorder sees only the screen's own
/// announcement; the view model's "Saved…" and messages go to its own closure.
@MainActor
struct StarterContactsScreenAnnouncementTests {
    @MainActor
    private final class Recorder {
        private(set) var announcements: [String] = []
        func record(_ message: String) { announcements.append(message) }
    }

    private static func host(
        _ viewModel: StarterContactsViewModel,
        recorder: Recorder
    ) async -> UIWindow {
        let screen = NavigationStack {
            StarterContactsScreen(viewModel: viewModel, onFinish: {}, announce: { recorder.record($0) })
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: screen)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        // The screen loads the view model from its own `.task`.
        _ = await eventuallyPumpingRunLoop { viewModel.loadState == .loaded }
        return window
    }

    private static func person(_ name: String) -> Contact {
        StarterContactsViewModelSaveTests.person(name)
    }

    @Test("A save with writes announces Saving once while it is still writing, and nothing when it ends")
    func savingIsAnnouncedOnceWhenASaveWithWritesStarts() async throws {
        let store = try StarterContactsViewModelSaveTests.store()
        let ana = Self.person("Ana")
        try await store.upsert(ana)
        let gate = AsyncGate()
        let viewModel = StarterContactsViewModel(
            contacts: ScriptedTrackingContactRepository(store, gate: gate),
            announce: { _ in },
            onSaved: { _ in }
        )
        let recorder = Recorder()
        let window = await Self.host(viewModel, recorder: recorder)
        defer { window.isHidden = true }
        #expect(viewModel.loadState == .loaded)
        viewModel.toggle(ana.id)

        let saving = Task { @MainActor in await viewModel.save() }
        // Ana's write is held, so the screen is still saving.
        await gate.waitUntilArrived()

        #expect(viewModel.isSaving)
        #expect(await eventuallyPumpingRunLoop { recorder.announcements.count == 1 })
        #expect(recorder.announcements == ["Saving"])

        await gate.open()
        #expect(await saving.value)
        // Give a late announcement time to land before asserting there is none.
        await settleViewUpdate(iterations: 20)
        #expect(recorder.announcements == ["Saving"])
    }

    @Test("Skip and a save with nothing to write announce nothing")
    func skipAndNoOpSaveAnnounceNothing() async throws {
        let store = try StarterContactsViewModelSaveTests.store()
        let ana = Self.person("Ana")
        try await store.upsert(ana)
        let viewModel = StarterContactsViewModel(contacts: store, announce: { _ in }, onSaved: { _ in })
        let recorder = Recorder()
        let window = await Self.host(viewModel, recorder: recorder)
        defer { window.isHidden = true }
        #expect(viewModel.loadState == .loaded)

        #expect(!(await viewModel.save()))
        viewModel.toggle(ana.id)
        #expect(viewModel.skip())
        await settleViewUpdate(iterations: 20)

        #expect(recorder.announcements.isEmpty)
    }
}
