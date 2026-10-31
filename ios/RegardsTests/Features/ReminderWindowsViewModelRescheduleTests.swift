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
        let failingReads = FailingFetchWindowRepository(
            wrapped: world.environment.window, failingCalls: { $0 > 1 })
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

    /// After a reset clears the override but the pass (or the global re-read)
    /// fails, the editor holds no override and an unedited draft. Save must
    /// still rerun the pass with the global window, as the message promises
    /// ("Save retries"), and never create an override from the draft.
    enum ResetFailure: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case passFails
        case globalReadFails

        var testDescription: String { rawValue }
    }

    @Test(
        "Save after a failed reset runs the reschedule again and stores no override",
        arguments: ResetFailure.allCases
    )
    func saveAfterAFailedResetRetriesTheReschedule(failure: ResetFailure) async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Fixtures.bystanderOverride)
        let recorder = Fixtures.SaveRecorder()
        // Call 1 is the load; call 2 is the reset's read; call 3 is the retry's.
        let reads = FailingFetchWindowRepository(
            wrapped: world.environment.window, failingCalls: { failure == .globalReadFails && $0 == 2 })
        let editor = Fixtures.editor(
            .contact(world.target.id), contacts: world.environment.contacts, window: reads, recorder: recorder)
        await editor.load()
        recorder.rescheduled = failure != .passFails
        #expect(!(await editor.resetToDefault()))
        #expect(editor.validationMessage == Self.message)
        let windowsAfterReset = recorder.windows.count
        recorder.rescheduled = true

        let saved = await editor.save()

        #expect(saved)
        #expect(editor.validationMessage == nil)
        #expect(recorder.windows.count == windowsAfterReset + 1, "the retry ran the pass")
        #expect(recorder.windows.last == Fixtures.storedGlobal, "with the global window the contact follows")
        #expect(!editor.hasStoredOverride)
        #expect(try await world.environment.contacts.fetch(id: world.target.id)?.reminderWindowOverride == nil)
        #expect(editor.draft == Draft(Fixtures.storedGlobal))
    }

    /// A retry that fails again keeps the editor open and the debt owed, so
    /// the next Save tries once more.
    @Test("A retry that fails again stays open, and the next Save still reruns the pass")
    func failedRetryAfterAResetStaysOwed() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Fixtures.bystanderOverride)
        let recorder = Fixtures.SaveRecorder()
        recorder.rescheduled = false
        let editor = await Self.loadedEditor(.contact(world.target.id), world: world, recorder: recorder)
        #expect(!(await editor.resetToDefault()))

        #expect(!(await editor.save()))
        #expect(editor.validationMessage == Self.message)
        recorder.rescheduled = true
        let saved = await editor.save()

        #expect(saved)
        #expect(recorder.windows.count == 3)
        #expect(try await world.environment.contacts.fetch(id: world.target.id)?.reminderWindowOverride == nil)
    }

    // MARK: - A reset whose global re-read fails

    /// An editor on a contact with a stored override, whose second global
    /// read (the reset's) fails and later reads succeed. Draft edits are made
    /// by the test before it resets.
    private static func editorWhoseResetReadFails(
        world: Fixtures.World, recorder: Fixtures.SaveRecorder
    ) async -> ReminderWindowsViewModel {
        let reads = FailingFetchWindowRepository(wrapped: world.environment.window, failingCalls: { $0 == 2 })
        let editor = Fixtures.editor(
            .contact(world.target.id), contacts: world.environment.contacts, window: reads, recorder: recorder)
        await editor.load()
        return editor
    }

    /// Edits made before "Use default window" are abandoned by that choice.
    /// When the reset's global re-read fails, Save must not turn them into an
    /// override: it reruns the pass and writes nothing.
    @Test("Save after edits and a reset whose read failed stores no override")
    func saveAfterEditThenFailedReadResetStoresNoOverride() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Fixtures.bystanderOverride)
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.editorWhoseResetReadFails(world: world, recorder: recorder)
        editor.draft.allowedDays = .saturday
        #expect(!(await editor.resetToDefault()))
        #expect(editor.validationMessage == Self.message)

        let saved = await editor.save()

        #expect(saved)
        #expect(editor.validationMessage == nil)
        #expect(recorder.windows == [Fixtures.storedGlobal], "only the retry ran the pass, with the global window")
        #expect(try await world.environment.contacts.fetch(id: world.target.id)?.reminderWindowOverride == nil)
        #expect(!editor.hasStoredOverride)
        #expect(editor.draft == Draft(Fixtures.storedGlobal))
    }

    @Test("A reset whose read failed shows the default window the editor last read, not the abandoned edits")
    func failedReadResetShowsTheDefaultWindow() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Fixtures.bystanderOverride)
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.editorWhoseResetReadFails(world: world, recorder: recorder)
        editor.draft.allowedDays = .saturday

        let reset = await editor.resetToDefault()

        #expect(!reset)
        #expect(editor.draft == Draft(Fixtures.storedGlobal))
        #expect(!editor.hasStoredOverride)
        #expect(recorder.windows.isEmpty)
    }

    /// After the failed reset the contact follows the default, so an edit now
    /// is a new override built from the default window the form shows.
    @Test("An edit after a reset whose read failed saves as a new override from the default window")
    func editAfterFailedReadResetSavesAnOverrideFromTheDefault() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Fixtures.bystanderOverride)
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.editorWhoseResetReadFails(world: world, recorder: recorder)
        #expect(!(await editor.resetToDefault()))
        editor.draft.allowedDays = .saturday

        let saved = await editor.save()

        #expect(saved)
        let stored = try #require(
            try await world.environment.contacts.fetch(id: world.target.id)?.reminderWindowOverride)
        #expect(stored.allowedDays == .saturday)
        #expect(stored.allowedTimeRanges == Fixtures.storedGlobal.allowedTimeRanges)
        #expect(stored.quietHours == Fixtures.storedGlobal.quietHours)
        #expect(recorder.windows.count == 1)
        #expect(editor.hasStoredOverride)
    }

    /// Pin. A save whose pass failed leaves the draft as the user left it; if
    /// they edit again, the next Save writes the newer edits.
    @Test("Save after a failed save writes the newer edits")
    func saveAfterFailedSaveWritesTheNewerEdits() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        recorder.rescheduled = false
        let editor = await Self.loadedEditor(.contact(world.target.id), world: world, recorder: recorder)
        editor.draft.allowedDays = .saturday
        #expect(!(await editor.save()))

        editor.draft.allowedDays = .sunday
        recorder.rescheduled = true
        let saved = await editor.save()

        #expect(saved)
        let stored = try await world.environment.contacts.fetch(id: world.target.id)
        #expect(stored?.reminderWindowOverride?.allowedDays == .sunday)
        #expect(recorder.windows.count == 2)
        #expect(recorder.windows.last?.allowedDays == .sunday)
    }

    // MARK: - The Saving… cue

    enum Action: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case save
        case reset

        var testDescription: String { rawValue }
    }

    /// The screen reads `saveButtonTitle` for Save's label and dims the form
    /// and the reset button while `isSaving`. A hosted SwiftUI button exposes
    /// no accessibility element to a unit test (see
    /// `SettingsNotificationsHostingTests`), so this test checks the label
    /// text and `isSaving` at the view-model level. The spoken cue is checked
    /// in `ReminderWindowsScreenAnnouncementTests`; the dimming itself is not
    /// covered by an automated test and is on the pre-release device pass.
    @Test("Save reads Saving… while the pass runs, then Save again", arguments: Action.allCases)
    func savingCueShowsWhileThePassRuns(action: Action) async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Fixtures.bystanderOverride)
        let gate = AsyncGate()
        let editor = ReminderWindowsViewModel(
            target: .contact(world.target.id),
            window: world.environment.window,
            contacts: world.environment.contacts,
            clock: { Fixtures.now },
            onSaved: { _ in
                await gate.wait()
                return true
            })
        await editor.load()
        editor.draft.allowedDays = .saturday
        #expect(editor.saveButtonTitle == "Save")
        #expect(!editor.isSaving)

        let running = Task { @MainActor in
            switch action {
            case .save: await editor.save()
            case .reset: await editor.resetToDefault()
            }
        }
        await gate.waitUntilArrived()

        #expect(editor.isSaving)
        #expect(editor.saveButtonTitle == "Saving\u{2026}")

        await gate.open()
        let finished = await running.value

        #expect(finished)
        #expect(!editor.isSaving)
        #expect(editor.saveButtonTitle == "Save")
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
