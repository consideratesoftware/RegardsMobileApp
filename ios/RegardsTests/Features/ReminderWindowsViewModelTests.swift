import Foundation
import Testing
@testable import Regards

/// TF-05 slice 3, global target: the editor's save-time validation (I1). Every
/// refusal must leave the whole store untouched and skip `onSaved`; every
/// success writes exactly the draft plus the stored zone, never a new one.
@MainActor
struct ReminderWindowsViewModelTests {

    private typealias Fixtures = ReminderWindowEditorFixtures

    private static func globalEditor(
        _ world: Fixtures.World,
        recorder: Fixtures.SaveRecorder
    ) async -> ReminderWindowsViewModel {
        let editor = Fixtures.editor(.global, world: world, recorder: recorder)
        await editor.load()
        return editor
    }

    /// Asserts a refused save changed nothing anywhere and said why.
    private static func expectRefused(
        _ saved: Bool,
        editor: ReminderWindowsViewModel,
        world: Fixtures.World,
        before: Fixtures.StoreSnapshot,
        recorder: Fixtures.SaveRecorder
    ) async throws {
        #expect(!saved)
        #expect(editor.validationMessage != nil)
        #expect(try await world.snapshot() == before)
        #expect(recorder.windows.isEmpty)
    }

    @Test("Quiet hours that cover every allowed range refuse the save and write nothing")
    func zeroCapacityRefusesSave() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.globalEditor(world, recorder: recorder)
        let before = try await world.snapshot()
        editor.draft.allowedDays = .allDays
        editor.draft.allowedTimeRanges = [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))]
        editor.draft.quietHours = TimeRange(start: TimeOfDay(hour: 17), end: TimeOfDay(hour: 23))

        let saved = await editor.save()

        try await Self.expectRefused(saved, editor: editor, world: world, before: before, recorder: recorder)
        #expect(editor.validationMessage?.localizedCaseInsensitiveContains("quiet") == true)
    }

    @Test("An allowed range that wraps midnight is rejected")
    func wrappingAllowedRangeRejected() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.globalEditor(world, recorder: recorder)
        let before = try await world.snapshot()
        editor.draft.allowedTimeRanges = [TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 1))]

        let saved = await editor.save()

        try await Self.expectRefused(saved, editor: editor, world: world, before: before, recorder: recorder)
        // The repository also refuses this window, with a generic "try again"
        // failure. The editor must catch it first and say what is wrong.
        #expect(editor.validationMessage?.localizedCaseInsensitiveContains("quiet hours can run past midnight") == true)
    }

    @Test("Quiet hours that wrap midnight save, and nothing but the draft changes")
    func quietHoursWrapSaves() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.globalEditor(world, recorder: recorder)
        let before = try await world.snapshot()
        let quiet = TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 7))
        editor.draft.quietHours = quiet

        let saved = await editor.save()

        #expect(saved)
        #expect(editor.validationMessage == nil)
        let after = try await world.snapshot()
        let stored = before.global
        let expected = ReminderWindow(
            allowedDays: stored.allowedDays,
            allowedTimeRanges: stored.allowedTimeRanges,
            quietHours: quiet,
            timezoneIdentifier: stored.timezoneIdentifier,
            occasionTime: stored.occasionTime,
            digestHorizonDays: stored.digestHorizonDays
        )
        #expect(after.global == expected)
        #expect(after.target == before.target)
        #expect(after.bystander == before.bystander)
        #expect(recorder.windows == [expected])
    }

    @Test(
        "Overlapping allowed ranges are rejected; touching ranges are allowed",
        arguments: [
            (overlapping: true, ranges: [(10, 12), (11, 13)]),
            (overlapping: false, ranges: [(10, 12), (12, 14)]),
        ]
    )
    func overlapRejectedTouchingAllowed(overlapping: Bool, ranges: [(Int, Int)]) async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.globalEditor(world, recorder: recorder)
        let before = try await world.snapshot()
        editor.draft.allowedTimeRanges = ranges.map {
            TimeRange(start: TimeOfDay(hour: $0.0), end: TimeOfDay(hour: $0.1))
        }

        let saved = await editor.save()

        if overlapping {
            try await Self.expectRefused(saved, editor: editor, world: world, before: before, recorder: recorder)
        } else {
            #expect(saved)
            #expect(try await world.snapshot().global.allowedTimeRanges == editor.draft.allowedTimeRanges)
        }
    }

    @Test("Deselecting every day is rejected")
    func noDaysRejected() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.globalEditor(world, recorder: recorder)
        let before = try await world.snapshot()
        editor.draft.allowedDays = []

        let saved = await editor.save()

        try await Self.expectRefused(saved, editor: editor, world: world, before: before, recorder: recorder)
        // Same as the wrapping case: the editor's own message, not the repository's generic failure.
        #expect(editor.validationMessage == "Pick at least one day.")
        // With quiet hours turned off there is nothing quiet to blame.
        editor.draft.quietHours = nil
        #expect(!(await editor.save()))
        #expect(editor.validationMessage?.localizedCaseInsensitiveContains("quiet") == false)
    }

    @Test("Quiet hours whose start equals their end are rejected")
    func quietZeroLengthRejected() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.globalEditor(world, recorder: recorder)
        let before = try await world.snapshot()
        editor.draft.quietHours = TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 22))

        let saved = await editor.save()

        try await Self.expectRefused(saved, editor: editor, world: world, before: before, recorder: recorder)
    }

    @Test(
        "A failed save keeps the draft, shows the error, leaves the store identical, and skips onSaved",
        arguments: [false, true]
    )
    func saveFailureKeepsDraft(contactTarget: Bool) async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        // Every write on these repositories throws; reads still work.
        let failingContacts = StubContactRepository.failingUpsert([world.target, world.bystander])
        let failingWindow = ThrowingSaveWindowRepository(wrapped: world.environment.window)
        let target: ReminderWindowsViewModel.Target = contactTarget ? .contact(world.target.id) : .global
        let editor = Fixtures.editor(target, contacts: failingContacts, window: failingWindow, recorder: recorder)
        await editor.load()
        let before = try await Fixtures.World.snapshot(
            window: failingWindow, contacts: failingContacts,
            targetID: world.target.id, bystanderID: world.bystander.id
        )
        editor.draft.allowedDays = .saturday
        editor.draft.allowedTimeRanges = [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 10))]
        editor.draft.quietHours = nil

        let saved = await editor.save()

        #expect(!saved)
        #expect(editor.validationMessage != nil)
        #expect(editor.draft.allowedDays == .saturday)
        #expect(editor.draft.allowedTimeRanges == [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 10))])
        #expect(editor.draft.quietHours == nil)
        let after = try await Fixtures.World.snapshot(
            window: failingWindow, contacts: failingContacts,
            targetID: world.target.id, bystanderID: world.bystander.id
        )
        #expect(after == before)
        #expect(recorder.windows.isEmpty)
    }

    /// The editor's analogue of the deep-link rule `isValid ⟹ build`: the
    /// message is nil exactly when the store changed.
    @Test("validationMessage is nil exactly when the save wrote", arguments: DraftCase.allCases)
    func validationNilIffSaveWrites(draft: DraftCase) async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.globalEditor(world, recorder: recorder)
        let before = try await world.snapshot()
        editor.draft.digestHorizonDays = 7 // differs from the stored 30, so a write is visible
        draft.apply(to: editor)

        let saved = await editor.save()

        let after = try await world.snapshot()
        #expect((editor.validationMessage == nil) == (after.global != before.global))
        #expect(saved == (editor.validationMessage == nil))
        #expect(saved == draft.saves)
        #expect(recorder.windows.count == (saved ? 1 : 0))
        #expect(after.target == before.target)
        #expect(after.bystander == before.bystander)
    }

    /// R55 evidence: the editor cannot change the zone. The stored zone is
    /// Lord Howe, so a save that took the device zone would read differently
    /// on any host that is not at Lord Howe.
    @Test("Saving the global window keeps the stored time zone")
    func saveNeverChangesTimezone() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.globalEditor(world, recorder: recorder)
        editor.draft.allowedDays = .saturday

        let saved = await editor.save()

        #expect(saved)
        #expect(try await world.environment.window.fetchGlobal().timezoneIdentifier == "Australia/Lord_Howe")
        #expect(recorder.windows.first?.timezoneIdentifier == "Australia/Lord_Howe")
    }

    /// 2026-03-08 is the US spring-forward Sunday: 02:00 to 03:00 does not
    /// exist that day, but it does on every other Sunday, so the window has
    /// capacity and must save.
    @Test("A Sunday 02:00 window saves on the spring-forward Sunday")
    func saveAllowedForSundayWindowOnSpringForwardDay() async throws {
        let newYork = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
            timezoneIdentifier: "America/New_York",
            occasionTime: TimeOfDay(hour: 7, minute: 15),
            digestHorizonDays: 30
        )
        let world = try await Fixtures.makeWorld(global: newYork)
        let recorder = Fixtures.SaveRecorder()
        let clock = try #require(ISO8601DateFormatter().date(from: "2026-03-08T06:30:00Z")) // 01:30 EST
        let editor = Fixtures.editor(.global, world: world, recorder: recorder, now: clock)
        await editor.load()
        let sundayRange = TimeRange(start: TimeOfDay(hour: 2), end: TimeOfDay(hour: 3))
        editor.draft.allowedDays = .sunday
        editor.draft.allowedTimeRanges = [sundayRange]

        let saved = await editor.save()

        #expect(saved)
        let stored = try await world.environment.window.fetchGlobal()
        #expect(stored.allowedDays == .sunday)
        #expect(stored.allowedTimeRanges == [sundayRange])
        #expect(stored.timezoneIdentifier == "America/New_York")
        #expect(stored.occasionTime == TimeOfDay(hour: 7, minute: 15))
        #expect(stored.digestHorizonDays == 30)
    }

    enum DraftCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case valid, quietWraps, touchingRanges
        case noDays, wrappingRange, overlappingRanges, zeroLengthRange, zeroLengthQuiet, zeroCapacity

        var testDescription: String { rawValue }

        var saves: Bool {
            switch self {
            case .valid, .quietWraps, .touchingRanges: true
            case .noDays, .wrappingRange, .overlappingRanges, .zeroLengthRange, .zeroLengthQuiet, .zeroCapacity: false
            }
        }

        @MainActor
        func apply(to editor: ReminderWindowsViewModel) {
            func range(_ start: Int, _ end: Int) -> TimeRange {
                TimeRange(start: TimeOfDay(hour: start), end: TimeOfDay(hour: end))
            }
            switch self {
            case .valid: break
            case .quietWraps: editor.draft.quietHours = range(22, 7)
            case .touchingRanges: editor.draft.allowedTimeRanges = [range(10, 12), range(12, 14)]
            case .noDays: editor.draft.allowedDays = []
            case .wrappingRange: editor.draft.allowedTimeRanges = [range(22, 1)]
            case .overlappingRanges: editor.draft.allowedTimeRanges = [range(10, 12), range(11, 13)]
            case .zeroLengthRange: editor.draft.allowedTimeRanges = [range(10, 10)]
            case .zeroLengthQuiet: editor.draft.quietHours = range(22, 22)
            case .zeroCapacity:
                editor.draft.allowedDays = .allDays
                editor.draft.allowedTimeRanges = [range(18, 22)]
                editor.draft.quietHours = range(17, 23)
            }
        }
    }
}
