import Foundation
import Testing
@testable import Regards

/// TF-05 slice 3, contact target: a per-contact override (I3, I5). The editor
/// writes the target contact's override column and nothing else: not the
/// global window, not another contact's override, not the zone, occasion time
/// or horizon (those are copied from the global window at save).
@MainActor
struct ReminderWindowsViewModelOverrideTests {

    private typealias Fixtures = ReminderWindowEditorFixtures

    private static let saturdayMorning = ReminderWindow(
        allowedDays: .saturday,
        allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12))],
        quietHours: nil,
        timezoneIdentifier: Fixtures.storedGlobal.timezoneIdentifier,
        occasionTime: Fixtures.storedGlobal.occasionTime,
        digestHorizonDays: Fixtures.storedGlobal.digestHorizonDays
    )

    @Test("A contact save writes only that contact's override and copies zone, occasion time and horizon from global")
    func contactSaveWritesOverrideNotGlobal() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = Fixtures.editor(.contact(world.target.id), world: world, recorder: recorder)
        await editor.load()
        let before = try await world.snapshot()
        editor.draft.allowedDays = .saturday
        editor.draft.allowedTimeRanges = [TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12))]
        editor.draft.quietHours = nil
        // The override editor does not offer these, and a save must not use them.
        editor.draft.occasionTime = TimeOfDay(hour: 3)
        editor.draft.digestHorizonDays = 7

        let saved = await editor.save()

        #expect(saved)
        let after = try await world.snapshot()
        #expect(after.global == before.global)
        #expect(after.bystander == before.bystander)
        var expectedTarget = before.target
        expectedTarget?.reminderWindowOverride = Self.saturdayMorning
        #expect(after.target == expectedTarget)
    }

    /// I3: the editor never changes a zone, and an override is always stamped
    /// with the global zone, occasion time and horizon at save. An override
    /// stored with different values for all three (say, written before the
    /// global zone changed) must come out aligned with the global window;
    /// only its days, ranges and quiet hours are the user's to keep.
    @Test("Re-saving an override replaces its zone, occasion time and horizon with the global ones")
    func resaveAlignsOverrideWithGlobalZoneOccasionAndHorizon() async throws {
        let quiet = TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 6))
        let drifted = ReminderWindow(
            allowedDays: [.saturday, .sunday],
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12))],
            quietHours: quiet,
            timezoneIdentifier: "Pacific/Kiritimati",
            occasionTime: TimeOfDay(hour: 3),
            digestHorizonDays: 7
        )
        #expect(drifted.timezoneIdentifier != Fixtures.storedGlobal.timezoneIdentifier)
        #expect(drifted.occasionTime != Fixtures.storedGlobal.occasionTime)
        #expect(drifted.digestHorizonDays != Fixtures.storedGlobal.digestHorizonDays)
        let world = try await Fixtures.makeWorld(targetOverride: drifted)
        let editor = Fixtures.editor(.contact(world.target.id), world: world, recorder: Fixtures.SaveRecorder())
        await editor.load()
        let before = try await world.snapshot()

        let saved = await editor.save()

        #expect(saved)
        let after = try await world.snapshot()
        let expected = ReminderWindow(
            allowedDays: drifted.allowedDays,
            allowedTimeRanges: drifted.allowedTimeRanges,
            quietHours: quiet,
            timezoneIdentifier: Fixtures.storedGlobal.timezoneIdentifier,
            occasionTime: Fixtures.storedGlobal.occasionTime,
            digestHorizonDays: Fixtures.storedGlobal.digestHorizonDays
        )
        #expect(after.target?.reminderWindowOverride == expected)
        #expect(after.global == before.global)
        #expect(after.bystander == before.bystander)
    }

    @Test("Saving after a failed load writes nothing")
    func saveAfterFailedLoadWritesNothing() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let flaky = FailFirstFetchWindowRepository(wrapped: world.environment.window, counter: CallCounter())
        let editor = Fixtures.editor(.global, contacts: world.environment.contacts, window: flaky, recorder: recorder)
        await editor.load()
        #expect(editor.loadState == .failed)
        let before = try await world.snapshot()
        // The draft is still the editor's seed, not the stored window.
        editor.draft.allowedDays = .sunday

        let saved = await editor.save()

        #expect(!saved)
        #expect(try await world.snapshot() == before)
        #expect(recorder.windows.isEmpty)
    }

    @Test("An archived contact's editor fails to load instead of presenting an editable window")
    func archivedContactDoesNotLoad() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Self.saturdayMorning)
        try await world.environment.contacts.archive(id: world.target.id, at: Fixtures.now)
        let editor = Fixtures.editor(.contact(world.target.id), world: world, recorder: Fixtures.SaveRecorder())

        await editor.load()

        #expect(editor.loadState == .failed)
        #expect(editor.loadFailureMessage == "This contact is no longer available.")
        #expect(editor.contactName == nil)
        #expect(!editor.hasStoredOverride)
        let saved = await editor.save()
        #expect(!saved)
    }

    @Test("Saving for a contact archived after load reports failure and writes nothing")
    func saveForContactArchivedAfterLoadFails() async throws {
        let world = try await Fixtures.makeWorld()
        let recorder = Fixtures.SaveRecorder()
        let editor = Fixtures.editor(.contact(world.target.id), world: world, recorder: recorder)
        await editor.load()
        try await world.environment.contacts.archive(id: world.target.id, at: Fixtures.now)
        let before = try await world.snapshot()
        editor.draft.allowedDays = .saturday

        let saved = await editor.save()

        #expect(!saved)
        #expect(editor.validationMessage != nil)
        #expect(!editor.hasStoredOverride)
        #expect(try await world.snapshot() == before)
        #expect(recorder.windows.isEmpty)
    }

    @Test("Using the default window for a contact archived after load reports failure")
    func resetForContactArchivedAfterLoadFails() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Self.saturdayMorning)
        let editor = Fixtures.editor(.contact(world.target.id), world: world, recorder: Fixtures.SaveRecorder())
        await editor.load()
        try await world.environment.contacts.archive(id: world.target.id, at: Fixtures.now)
        let before = try await world.snapshot()

        let cleared = await editor.resetToDefault()

        #expect(!cleared)
        #expect(editor.validationMessage != nil)
        #expect(editor.hasStoredOverride)
        #expect(try await world.snapshot() == before)
    }

    @Test("Using the default window clears that contact's override and touches nothing else")
    func resetToDefaultClearsOverride() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Self.saturdayMorning)
        let recorder = Fixtures.SaveRecorder()
        let editor = Fixtures.editor(.contact(world.target.id), world: world, recorder: recorder)
        await editor.load()
        let before = try await world.snapshot()
        #expect(before.target?.reminderWindowOverride != nil)

        let cleared = await editor.resetToDefault()

        #expect(cleared)
        let after = try await world.snapshot()
        #expect(after.global == before.global)
        #expect(after.bystander == before.bystander)
        var expectedTarget = before.target
        expectedTarget?.reminderWindowOverride = nil
        #expect(after.target == expectedTarget)
    }

    @Test("A failed Use default window keeps the override, says why, and counts the failure")
    func resetToDefaultFailureKeepsOverride() async throws {
        let world = try await Fixtures.makeWorld(targetOverride: Self.saturdayMorning)
        // Reads work; every write (including the override clear) throws.
        let failing = StubContactRepository.failingUpsert([world.target, world.bystander])
        let editor = Fixtures.editor(
            .contact(world.target.id), contacts: failing, window: world.environment.window,
            recorder: Fixtures.SaveRecorder()
        )
        await editor.load()
        #expect(editor.hasStoredOverride)

        let cleared = await editor.resetToDefault()

        #expect(!cleared)
        #expect(editor.hasStoredOverride)
        #expect(editor.validationMessage == "Couldn't switch back to the default window. Try again.")
        #expect(editor.failureCount == 1)
        #expect(try await failing.fetch(id: world.target.id)?.reminderWindowOverride == Self.saturdayMorning)
    }

    @Test("A contact without an override opens on the global window; one with an override opens on it")
    func contactEditorLoadsEffectiveWindow() async throws {
        let withoutOverride = try await Fixtures.makeWorld()
        let withOverride = try await Fixtures.makeWorld(targetOverride: Self.saturdayMorning)
        let recorder = Fixtures.SaveRecorder()
        let plain = Fixtures.editor(.contact(withoutOverride.target.id), world: withoutOverride, recorder: recorder)
        let overridden = Fixtures.editor(.contact(withOverride.target.id), world: withOverride, recorder: recorder)

        await plain.load()
        await overridden.load()

        #expect(plain.draft.allowedDays == Fixtures.storedGlobal.allowedDays)
        #expect(plain.draft.allowedTimeRanges == Fixtures.storedGlobal.allowedTimeRanges)
        #expect(plain.draft.quietHours == Fixtures.storedGlobal.quietHours)
        #expect(overridden.draft.allowedDays == .saturday)
        #expect(overridden.draft.allowedTimeRanges == Self.saturdayMorning.allowedTimeRanges)
        #expect(overridden.draft.quietHours == nil)
    }

    /// A v1-shaped override has no occasion time or horizon. It must load with
    /// the defaults and save as a valid window; the save copies the global
    /// occasion time and horizon in (I3), so the stored result carries 07:15
    /// and 30, not 09:00 and 14.
    @Test("An override stored before v2 loads and re-saves as a valid window")
    func editorLoadsPreV2OverrideBlob() async throws {
        let contact = UpcomingFixtures.contact(systemRef: "pre-v2", displayName: "Pre v2", cadenceDays: 7)
        var blob = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.saturdayMorning)) as? [String: Any]
        )
        blob.removeValue(forKey: "occasionTime")
        blob.removeValue(forKey: "digestHorizonDays")
        let json = try #require(String(
            data: JSONSerialization.data(withJSONObject: blob, options: [.sortedKeys]), encoding: .utf8
        ))
        #expect(!json.contains("occasionTime") && !json.contains("digestHorizonDays"))
        let environment = try await RawOverrideStore.makeEnvironment(
            global: Fixtures.storedGlobal, contact: contact, rawOverrideJSON: json
        )
        let recorder = Fixtures.SaveRecorder()
        let editor = Fixtures.editor(
            .contact(contact.id), contacts: environment.contacts, window: environment.window, recorder: recorder
        )

        await editor.load()

        #expect(editor.draft.allowedDays == .saturday)
        #expect(editor.draft.allowedTimeRanges == Self.saturdayMorning.allowedTimeRanges)
        let saved = await editor.save()
        #expect(saved)
        let stored = try #require(try await environment.contacts.fetch(id: contact.id)?.reminderWindowOverride)
        #expect(stored == Self.saturdayMorning)
        #expect(try await environment.window.fetchGlobal() == Fixtures.storedGlobal)
    }

    /// The contact's row moves as soon as the override is saved, with no
    /// reload by the caller: Upcoming follows `observeTracked()`.
    @Test("Saving an override moves that contact's Upcoming row live")
    func overrideSaveMovesUpcomingRowLive() async throws {
        let global = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay.endOfDay)],
            timezoneIdentifier: "Etc/UTC",
            occasionTime: TimeOfDay(hour: 7, minute: 15),
            digestHorizonDays: 30
        )
        let world = try await Fixtures.makeWorld(global: global)
        let environment = world.environment
        let now = Fixtures.now // a local, so the Sendable clocks below capture a value, not a main-actor static
        let upcoming = UpcomingViewModel(
            contacts: environment.contacts,
            reminders: environment.reminders,
            scheduler: SchedulingPass(
                reminders: environment.reminders,
                contacts: environment.contacts,
                window: environment.window,
                clock: { now }
            ),
            interactions: environment.interactions,
            window: global,
            clock: { now }
        )
        await upcoming.load()
        func targetRow() -> UpcomingRowState? {
            upcoming.groups.flatMap(\.rows).first { $0.contactId == world.target.id && $0.kind == .cadence }
        }
        // Overdue in an all-day window: the slot that contains now starts at midnight.
        #expect(targetRow()?.scheduledFor == ISO8601DateFormatter().date(from: "2027-01-15T00:00:00Z"))
        let bystanderBefore = try await world.snapshot().bystander
        let recorder = Fixtures.SaveRecorder()
        let editor = Fixtures.editor(.contact(world.target.id), world: world, recorder: recorder)
        await editor.load()
        editor.draft.allowedDays = .saturday
        editor.draft.allowedTimeRanges = [TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12))]

        let saved = await editor.save()

        #expect(saved)
        let moved = await eventuallyPumpingRunLoop {
            targetRow()?.scheduledFor == ISO8601DateFormatter().date(from: "2027-01-16T10:00:00Z")
        }
        #expect(moved)
        #expect(try await world.snapshot().bystander == bystanderBefore)
    }
}
