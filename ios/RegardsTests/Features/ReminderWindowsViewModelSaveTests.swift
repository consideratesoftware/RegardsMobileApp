import Foundation
import Testing
@testable import Regards

/// What a save writes, field by field, for both targets (I1, I3). Each test
/// checks the written values and that everything it must not touch is
/// unchanged: the other window, the other contacts, and `onSaved`.
@MainActor
struct ReminderWindowsViewModelSaveTests {

    private typealias Fixtures = ReminderWindowEditorFixtures
    typealias DraftCase = ReminderWindowsViewModelTests.DraftCase

    private static func loadedEditor(
        _ target: ReminderWindowsViewModel.Target,
        world: Fixtures.World,
        recorder: Fixtures.SaveRecorder,
        now: Date = Fixtures.now
    ) async -> ReminderWindowsViewModel {
        let editor = Fixtures.editor(target, world: world, recorder: recorder, now: now)
        await editor.load()
        return editor
    }

    private static func window(
        _ base: ReminderWindow,
        days: DayOfWeekMask? = nil,
        zone: String? = nil,
        occasionTime: TimeOfDay? = nil,
        horizon: Int? = nil
    ) -> ReminderWindow {
        ReminderWindow(
            allowedDays: days ?? base.allowedDays,
            allowedTimeRanges: base.allowedTimeRanges,
            quietHours: base.quietHours,
            timezoneIdentifier: zone ?? base.timezoneIdentifier,
            occasionTime: occasionTime ?? base.occasionTime,
            digestHorizonDays: horizon ?? base.digestHorizonDays
        )
    }

    @Test("Saving the global window stores the edited occasion time and nothing else changes")
    func globalSaveStoresEditedOccasionTime() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.loadedEditor(.global, world: world, recorder: recorder)
        #expect(editor.draft.occasionTime == TimeOfDay(hour: 7, minute: 15))
        let before = try await world.snapshot()
        editor.draft.occasionTime = TimeOfDay(hour: 8, minute: 30)

        let saved = await editor.save()

        #expect(saved)
        let expected = Self.window(Fixtures.storedGlobal, occasionTime: TimeOfDay(hour: 8, minute: 30))
        let after = try await world.snapshot()
        #expect(after.global == expected)
        #expect(recorder.windows == [expected])
        #expect(after.target == before.target)
        #expect(after.bystander == before.bystander)
    }

    @Test("Saving a contact override obeys the same refusals, writes only on success, and never touches global",
          arguments: ReminderWindowsViewModelTests.DraftCase.allCases)
    func contactValidationNilIffSaveWrites(draft: DraftCase) async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.loadedEditor(.contact(world.target.id), world: world, recorder: recorder)
        let before = try await world.snapshot()
        // A contact with no override opens on the global window, so an
        // untouched draft would be an unchanged save. Give every case a
        // difference from it first.
        editor.draft.allowedDays = .saturday
        draft.apply(to: editor)

        let saved = await editor.save()

        let after = try await world.snapshot()
        #expect(saved == draft.saves)
        #expect((editor.validationMessage == nil) == saved)
        let overrideChanged = after.target?.reminderWindowOverride != before.target?.reminderWindowOverride
        #expect(overrideChanged == saved)
        #expect(after.global == before.global)
        #expect(after.bystander == before.bystander)
        // onSaved runs only after a successful override save, and carries the
        // override just stored; the app uses it to re-run that contact.
        if saved {
            let stored = try #require(after.target?.reminderWindowOverride)
            #expect(recorder.windows == [stored])
        } else {
            #expect(recorder.windows.isEmpty)
        }
    }

    /// The zone comes from the window as loaded, so a change to the stored
    /// zone while the editor is open cannot slip in through a save.
    @Test("Saving the global window keeps the zone it loaded with, not one stored since")
    func globalSaveKeepsTheLoadedTimezone() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.loadedEditor(.global, world: world, recorder: recorder)
        try await world.environment.window.saveGlobal(
            Self.window(Fixtures.storedGlobal, zone: "Pacific/Kiritimati")
        )
        editor.draft.allowedDays = .saturday

        let saved = await editor.save()

        #expect(saved)
        let expected = Self.window(Fixtures.storedGlobal, days: .saturday)
        #expect(expected.timezoneIdentifier == "Australia/Lord_Howe")
        #expect(try await world.environment.window.fetchGlobal() == expected)
        #expect(recorder.windows == [expected])
    }

    /// An override is stamped from the global window as it is at save time,
    /// so it never lags a change made while the editor was open.
    @Test("An override save copies the latest global zone, occasion time and horizon")
    func overrideSaveCopiesTheLatestGlobal() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.loadedEditor(.contact(world.target.id), world: world, recorder: recorder)
        let loadedDraft = editor.draft
        let latest = Self.window(
            Fixtures.storedGlobal, zone: "Pacific/Kiritimati", occasionTime: TimeOfDay(hour: 3), horizon: 7
        )
        try await world.environment.window.saveGlobal(latest)
        editor.draft.allowedDays = .saturday

        let saved = await editor.save()

        #expect(saved)
        let contact = try #require(try await world.environment.contacts.fetch(id: world.target.id))
        let stored = try #require(contact.reminderWindowOverride)
        #expect(stored.timezoneIdentifier == "Pacific/Kiritimati")
        #expect(stored.occasionTime == TimeOfDay(hour: 3))
        #expect(stored.digestHorizonDays == 7)
        #expect(stored.allowedDays == .saturday)
        #expect(stored.allowedTimeRanges == loadedDraft.allowedTimeRanges)
        #expect(stored.quietHours == loadedDraft.quietHours)
        #expect(try await world.environment.window.fetchGlobal() == latest)
    }

    /// 2026-03-08 is the US spring-forward Sunday. From Saturday noon the
    /// next Sunday's 02:00 to 03:00 does not exist, but later Sundays have it,
    /// so the window has capacity.
    @Test("A Sunday 02:00 window saves the day before the spring-forward Sunday")
    func sundayWindowSavesTheDayBeforeSpringForward() async throws {
        let newYork = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
            timezoneIdentifier: "America/New_York",
            occasionTime: TimeOfDay(hour: 7, minute: 15),
            digestHorizonDays: 30
        )
        let world = try await Fixtures.makeWorld(global: newYork)
        let recorder = Fixtures.SaveRecorder()
        let saturdayNoon = try #require(ISO8601DateFormatter().date(from: "2026-03-07T17:00:00Z")) // 12:00 EST
        let editor = await Self.loadedEditor(.global, world: world, recorder: recorder, now: saturdayNoon)
        let sundayRange = TimeRange(start: TimeOfDay(hour: 2), end: TimeOfDay(hour: 3))
        editor.draft.allowedDays = .sunday
        editor.draft.allowedTimeRanges = [sundayRange]

        let saved = await editor.save()

        #expect(saved)
        #expect(editor.validationMessage == nil)
        let stored = try await world.environment.window.fetchGlobal()
        #expect(stored.allowedDays == .sunday)
        #expect(stored.allowedTimeRanges == [sundayRange])
        #expect(stored.timezoneIdentifier == "America/New_York")
    }

    /// Sunday Mar 1 2026, 03:00 EST. The only allowed time is Sunday 02:00 to
    /// 02:30, and Sunday Mar 8 has no 02:00 (spring forward), so the first slot
    /// is Sunday Mar 15, 14 days out. A save probes for capacity from the clock
    /// once; the engine's search has to reach that far on its own (R62).
    @Test("A window whose only slot is skipped by the spring-forward gap saves after one probe")
    func gapOnlyWindowSavesWithSingleProbe() async throws {
        let newYork = ReminderWindow(
            allowedDays: .weekdays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 22))],
            timezoneIdentifier: "America/New_York",
            occasionTime: TimeOfDay(hour: 7, minute: 15),
            digestHorizonDays: 30
        )
        let world = try await Fixtures.makeWorld(global: newYork)
        let recorder = Fixtures.SaveRecorder()
        let sundayEarlyMorning = try #require(ISO8601DateFormatter().date(from: "2026-03-01T08:00:00Z")) // 03:00 EST
        let editor = await Self.loadedEditor(.global, world: world, recorder: recorder, now: sundayEarlyMorning)
        let gapRange = TimeRange(start: TimeOfDay(hour: 2), end: TimeOfDay(hour: 2, minute: 30))
        editor.draft.allowedDays = .sunday
        editor.draft.allowedTimeRanges = [gapRange]

        let saved = await editor.save()

        #expect(saved)
        #expect(editor.validationMessage == nil)
        let stored = try await world.environment.window.fetchGlobal()
        #expect(stored.allowedDays == .sunday)
        #expect(stored.allowedTimeRanges == [gapRange])
        #expect(recorder.windows == [stored])
    }

    @Test("A contact with no override that saves an unchanged draft writes nothing and stays on the default")
    func unchangedContactSaveWritesNothing() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = await Self.loadedEditor(.contact(world.target.id), world: world, recorder: recorder)
        let before = try await world.snapshot()

        let saved = await editor.save()

        #expect(saved)
        #expect(editor.validationMessage == nil)
        #expect(!editor.hasStoredOverride)
        let after = try await world.snapshot()
        #expect(after == before)
        #expect(after.target?.reminderWindowOverride == nil)
        #expect(recorder.windows.isEmpty)
    }

    @Test("Trying again after a failed load recovers, and the recovered editor saves")
    func retryAfterFailedLoadRecovers() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let flaky = FailingFetchWindowRepository(wrapped: world.environment.window, failingCalls: { $0 == 1 })
        let editor = Fixtures.editor(.global, contacts: world.environment.contacts, window: flaky, recorder: recorder)

        await editor.load()
        #expect(editor.loadState == .failed)
        #expect(editor.loadFailureMessage == "Couldn't load your reminder window.")

        await editor.load()
        #expect(editor.loadState == .loaded)
        #expect(editor.draft == ReminderWindowsViewModel.Draft(Fixtures.storedGlobal))
        editor.draft.allowedDays = .saturday

        let saved = await editor.save()

        #expect(saved)
        #expect(try await world.environment.window.fetchGlobal().allowedDays == .saturday)
    }

    /// "Unchanged" means unchanged from what the editor loaded. If the global
    /// window moves while a contact's editor is open, an untouched Save must
    /// still leave the contact on the default; comparing against a fresh
    /// global would see a difference and create an override that freezes the
    /// old global values.
    @Test("An untouched contact save after the global window changed still creates no override")
    func untouchedContactSaveAfterGlobalChangeCreatesNoOverride() async throws {
        let world = try await Fixtures.makeWorld()
        let contactEditor = await Self.loadedEditor(
            .contact(world.target.id), world: world, recorder: Fixtures.SaveRecorder()
        )
        let globalEditor = await Self.loadedEditor(.global, world: world, recorder: Fixtures.SaveRecorder())
        globalEditor.draft.digestHorizonDays = 7
        #expect(await globalEditor.save())
        let before = try await world.snapshot()
        #expect(before.global.digestHorizonDays == 7)

        let saved = await contactEditor.save()

        #expect(saved)
        #expect(!contactEditor.hasStoredOverride)
        let after = try await world.snapshot()
        #expect(after.target?.reminderWindowOverride == nil)
        #expect(after == before)
    }
}
