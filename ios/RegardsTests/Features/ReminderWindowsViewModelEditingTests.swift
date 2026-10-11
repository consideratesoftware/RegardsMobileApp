import Foundation
import Testing
@testable import Regards

/// TF-05 slice 3: the editor's editing controls on the view model. Each test
/// checks the edit and that nothing else in the draft moved. The stored
/// fixture has ranges 10:00-12:00 and 14:00-16:00, quiet hours 21:00-06:00,
/// Mon to Sat, so an edit that reaches the wrong field shows.
@MainActor
struct ReminderWindowsViewModelEditingTests {

    private typealias Fixtures = ReminderWindowEditorFixtures

    private static func time(_ hour: Int, _ minute: Int = 0) -> TimeOfDay {
        TimeOfDay(hour: hour, minute: minute)
    }

    private static func range(_ start: Int, _ end: Int) -> TimeRange {
        TimeRange(start: time(start), end: time(end))
    }

    private static func loadedEditor(
        _ target: ReminderWindowsViewModel.Target = .global,
        world: Fixtures.World
    ) async -> ReminderWindowsViewModel {
        let editor = Fixtures.editor(target, world: world, recorder: Fixtures.SaveRecorder())
        await editor.load()
        return editor
    }

    @Test("Turning quiet hours off and on again restores the range that was set")
    func quietHoursToggleRestoresPreviousRange() async throws {
        let editor = await Self.loadedEditor(world: try await Fixtures.makeWorld())
        #expect(editor.quietHoursEnabled)
        let before = editor.draft

        editor.quietHoursEnabled = false
        #expect(editor.draft.quietHours == nil)
        #expect(!editor.quietHoursEnabled)
        editor.quietHoursEnabled = true

        #expect(editor.draft == before)
    }

    @Test("Quiet hours edited while on come back with the edited range after an off-on toggle")
    func quietHoursToggleRestoresEditedRange() async throws {
        let editor = await Self.loadedEditor(world: try await Fixtures.makeWorld())
        editor.setQuietHours(start: Self.time(23))

        editor.quietHoursEnabled = false
        editor.quietHoursEnabled = true

        #expect(editor.draft.quietHours == TimeRange(start: Self.time(23), end: Self.time(6)))
    }

    @Test("setQuietHours moves only the edited end")
    func setQuietHoursMovesOnlyTheEditedEnd() async throws {
        let editor = await Self.loadedEditor(world: try await Fixtures.makeWorld())
        let before = editor.draft

        editor.setQuietHours(start: Self.time(22))
        #expect(editor.draft.quietHours == TimeRange(start: Self.time(22), end: Self.time(6)))
        editor.setQuietHours(end: Self.time(7))
        #expect(editor.draft.quietHours == TimeRange(start: Self.time(22), end: Self.time(7)))

        var expected = before
        expected.quietHours = TimeRange(start: Self.time(22), end: Self.time(7))
        #expect(editor.draft == expected)
    }

    @Test("setRange moves only the edited end of only the edited range")
    func setRangeMovesOnlyTheEditedEnd() async throws {
        let editor = await Self.loadedEditor(world: try await Fixtures.makeWorld())
        let before = editor.draft

        editor.setRange(at: 0, start: Self.time(9))
        #expect(editor.draft.allowedTimeRanges == [Self.range(9, 12), Self.range(14, 16)])
        editor.setRange(at: 1, end: Self.time(17))
        #expect(editor.draft.allowedTimeRanges == [Self.range(9, 12), Self.range(14, 17)])
        editor.setRange(at: 5, start: Self.time(1)) // out of range: ignored
        #expect(editor.draft.allowedTimeRanges == [Self.range(9, 12), Self.range(14, 17)])

        var expected = before
        expected.allowedTimeRanges = [Self.range(9, 12), Self.range(14, 17)]
        #expect(editor.draft == expected)
    }

    @Test("addRange appends 09:00 to 10:00 and changes nothing else")
    func addRangeAppendsDefaultRange() async throws {
        let editor = await Self.loadedEditor(world: try await Fixtures.makeWorld())
        let before = editor.draft

        editor.addRange()

        var expected = before
        expected.allowedTimeRanges.append(Self.range(9, 10))
        #expect(editor.draft == expected)
        #expect(editor.draft.allowedTimeRanges.count == 3)
    }

    @Test("removeRange removes the chosen range but refuses the last one, and canRemoveRange agrees")
    func removeRangeRefusesTheLastRange() async throws {
        let editor = await Self.loadedEditor(world: try await Fixtures.makeWorld())
        #expect(editor.canRemoveRange)
        let before = editor.draft

        editor.removeRange(at: 7) // out of range: ignored
        #expect(editor.draft == before)
        editor.removeRange(at: 0)

        #expect(editor.draft.allowedTimeRanges == [Self.range(14, 16)])
        var expected = before
        expected.allowedTimeRanges = [Self.range(14, 16)]
        #expect(editor.draft == expected)
        #expect(!editor.canRemoveRange)

        editor.removeRange(at: 0)
        #expect(editor.draft.allowedTimeRanges == [Self.range(14, 16)])
    }

    @Test("toggleDay flips one day and leaves the rest")
    func toggleDayFlipsOneDay() async throws {
        let editor = await Self.loadedEditor(world: try await Fixtures.makeWorld())
        let before = editor.draft
        #expect(!editor.isDayAllowed(.sunday))

        editor.toggleDay(.sunday)
        #expect(editor.isDayAllowed(.sunday))
        editor.toggleDay(.monday)
        #expect(!editor.isDayAllowed(.monday))

        var expected = before
        expected.allowedDays = [.tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
        #expect(editor.draft == expected)
    }

    @Test("hasStoredOverride follows load, save and reset for a contact, and stays false for global")
    func hasStoredOverrideFollowsLoadSaveReset() async throws {
        let plainWorld = try await Fixtures.makeWorld()
        let plain = await Self.loadedEditor(.contact(plainWorld.target.id), world: plainWorld)
        #expect(!plain.hasStoredOverride)
        #expect(await plain.save())
        #expect(plain.hasStoredOverride)
        #expect(await plain.resetToDefault())
        #expect(!plain.hasStoredOverride)

        let override = Fixtures.bystanderOverride
        let overriddenWorld = try await Fixtures.makeWorld(targetOverride: override)
        let overridden = await Self.loadedEditor(.contact(overriddenWorld.target.id), world: overriddenWorld)
        #expect(overridden.hasStoredOverride)

        let global = await Self.loadedEditor(world: plainWorld)
        #expect(!global.hasStoredOverride)
        #expect(await global.save())
        #expect(!global.hasStoredOverride)
    }

    @Test("failureCount counts each refusal, not successes, and editing the draft clears the message")
    func failureCountCountsRefusals() async throws {
        let editor = await Self.loadedEditor(world: try await Fixtures.makeWorld())
        #expect(editor.failureCount == 0)
        editor.draft.allowedDays = []

        #expect(!(await editor.save()))
        #expect(editor.failureCount == 1)
        let message = editor.validationMessage
        #expect(message != nil)
        #expect(!(await editor.save()))
        #expect(editor.failureCount == 2)
        #expect(editor.validationMessage == message)

        editor.draft.allowedDays = .saturday
        #expect(editor.validationMessage == nil)
        #expect(await editor.save())
        #expect(editor.failureCount == 2)
    }
}
