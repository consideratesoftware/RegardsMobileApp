import Foundation
import Testing
@testable import Regards

/// After the write lands, a save or an override reset reschedules through
/// `onSaved`, which answers whether reminders were rescheduled. A `false`
/// keeps the editor open on `notRescheduledMessage` (the write already
/// happened, so it is not a failed save), and Save retries the reschedule.
@MainActor
struct ReminderWindowsViewModelRescheduleTests {

    private typealias Fixtures = ReminderWindowEditorFixtures
    private typealias Draft = ReminderWindowsViewModel.Draft
    private static let message = ReminderWindowsViewModel.notRescheduledMessage

    private static func loadedEditor(
        _ target: ReminderWindowsViewModel.Target,
        world: Fixtures.World,
        recorder: Fixtures.SaveRecorder
    ) async -> ReminderWindowsViewModel {
        let editor = Fixtures.editor(target, world: world, recorder: recorder)
        await editor.load()
        return editor
    }

    // MARK: - A failed pass keeps the editor open

    @Test("A global save whose pass fails stays open, says so, and has written the window")
    func globalSaveWhosePassFailsStaysOpenAndSaysSo() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        recorder.rescheduled = false
        let editor = await Self.loadedEditor(.global, world: world, recorder: recorder)
        editor.draft.allowedDays = .saturday

        let saved = await editor.save()

        #expect(!saved)
        #expect(editor.validationMessage == Self.message)
        #expect(editor.failureCount == 1)
        #expect(try await world.environment.window.fetchGlobal().allowedDays == .saturday)
        #expect(recorder.windows.count == 1)
    }

    @Test("An override save whose pass fails stays open, says so, and has stored the override")
    func overrideSaveWhosePassFailsStaysOpenAndSaysSo() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        recorder.rescheduled = false
        let editor = await Self.loadedEditor(.contact(world.target.id), world: world, recorder: recorder)
        editor.draft.allowedDays = .saturday

        let saved = await editor.save()

        #expect(!saved)
        #expect(editor.validationMessage == Self.message)
        #expect(editor.failureCount == 1)
        let stored = try await world.environment.contacts.fetch(id: world.target.id)
        #expect(stored?.reminderWindowOverride?.allowedDays == .saturday)
    }

    @Test("A reset whose pass fails stays open, says so, and has cleared the override")
    func resetWhosePassFailsStaysOpenAndSaysSo() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Fixtures.bystanderOverride)
        let recorder = Fixtures.SaveRecorder()
        recorder.rescheduled = false
        let editor = await Self.loadedEditor(.contact(world.target.id), world: world, recorder: recorder)

        let reset = await editor.resetToDefault()

        #expect(!reset)
        #expect(editor.validationMessage == Self.message)
        #expect(editor.failureCount == 1)
        #expect(editor.draft == Draft(Fixtures.storedGlobal))
        #expect(try await world.environment.contacts.fetch(id: world.target.id)?.reminderWindowOverride == nil)
    }

    @Test("A reset whose global read fails stays open and says so, without running the pass")
    func resetWhoseGlobalReadFailsStaysOpenAndSaysSo() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Fixtures.bystanderOverride)
        let recorder = Fixtures.SaveRecorder()
        let failingReads = FailAfterFirstFetchWindowRepository(
            wrapped: world.environment.window, counter: CallCounter())
        let editor = Fixtures.editor(
            .contact(world.target.id), contacts: world.environment.contacts, window: failingReads,
            recorder: recorder)
        await editor.load()
        #expect(editor.loadState == .loaded)

        let reset = await editor.resetToDefault()

        #expect(!reset)
        #expect(editor.validationMessage == Self.message)
        #expect(editor.failureCount == 1)
        #expect(recorder.windows.isEmpty)
        #expect(try await world.environment.contacts.fetch(id: world.target.id)?.reminderWindowOverride == nil)
    }

    // MARK: - Retrying

    @Test("Save after a failed pass runs the reschedule again", arguments: [true, false])
    func saveAfterAFailedPassRetriesTheReschedule(global: Bool) async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        recorder.rescheduled = false
        let target: ReminderWindowsViewModel.Target = global ? .global : .contact(world.target.id)
        let editor = await Self.loadedEditor(target, world: world, recorder: recorder)
        editor.draft.allowedDays = .saturday
        #expect(!(await editor.save()))

        recorder.rescheduled = true
        let retried = await editor.save()

        #expect(retried)
        #expect(editor.validationMessage == nil)
        #expect(recorder.windows.count == 2, "the second save ran onSaved again")
        #expect(recorder.windows.first == recorder.windows.last)
    }

    // MARK: - The return value and the message agree

    @Test(
        "save() returns true exactly when no message is left, and failureCount rises exactly when it is false",
        arguments: ReminderWindowsViewModelTests.DraftCase.allCases, [true, false]
    )
    func saveReturnsTrueIffNoMessage(
        draft: ReminderWindowsViewModelTests.DraftCase, rescheduled: Bool
    ) async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        recorder.rescheduled = rescheduled
        let editor = await Self.loadedEditor(.global, world: world, recorder: recorder)
        editor.draft.digestHorizonDays = 7 // differs from the stored 30, so a write is visible
        draft.apply(to: editor)

        let saved = await editor.save()

        #expect(saved == (draft.saves && rescheduled))
        #expect(saved == (editor.validationMessage == nil))
        #expect(editor.failureCount == (saved ? 0 : 1))
        if draft.saves, !rescheduled {
            #expect(editor.validationMessage == Self.message)
        }
    }

    // MARK: - Reset refreshes the draft

    @Test("After a reset the draft shows the global window, so an untouched Save writes no override")
    func resetRefreshesTheDraftToTheGlobalWindow() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Fixtures.bystanderOverride)
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.loadedEditor(.contact(world.target.id), world: world, recorder: recorder)
        #expect(editor.draft == Draft(Fixtures.bystanderOverride))

        let reset = await editor.resetToDefault()
        let savedAfterReset = await editor.save()

        #expect(reset)
        #expect(editor.draft == Draft(Fixtures.storedGlobal))
        #expect(savedAfterReset)
        #expect(try await world.environment.contacts.fetch(id: world.target.id)?.reminderWindowOverride == nil)
        #expect(recorder.windows == [Fixtures.storedGlobal], "only the reset ran onSaved")
    }

    // MARK: - Pins

    /// The screen dims Save and the reset button while `isSaving`, and the
    /// pass runs inside that span, so the cue shows for the pass's duration.
    @Test("The pass runs while the editor is saving, for a save and for a reset")
    func passRunsWhileSaving() async throws {
        final class Box { var editor: ReminderWindowsViewModel? }
        let world = try await Fixtures.makeWorld(targetOverride: Fixtures.bystanderOverride)
        let box = Box()
        var savingDuringPass: [Bool] = []
        let editor = ReminderWindowsViewModel(
            target: .contact(world.target.id),
            window: world.environment.window,
            contacts: world.environment.contacts,
            clock: { Fixtures.now },
            onSaved: { _ in
                savingDuringPass.append(box.editor?.isSaving ?? false)
                return true
            })
        box.editor = editor
        await editor.load()
        editor.draft.allowedDays = .saturday

        _ = await editor.save()
        _ = await editor.resetToDefault()

        #expect(savingDuringPass == [true, true])
        #expect(!editor.isSaving)
    }
}
