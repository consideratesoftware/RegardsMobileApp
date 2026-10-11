import Foundation
import GRDB
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
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let environment = ProductionRepositoryFactory.makeEnvironment(database: database)
        try await environment.window.saveGlobal(Fixtures.storedGlobal)
        let contact = UpcomingFixtures.contact(systemRef: "pre-v2", displayName: "Pre v2", cadenceDays: 7)
        try await environment.contacts.upsert(contact)
        var blob = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.saturdayMorning)) as? [String: Any]
        )
        blob.removeValue(forKey: "occasionTime")
        blob.removeValue(forKey: "digestHorizonDays")
        let json = try #require(String(
            data: JSONSerialization.data(withJSONObject: blob, options: [.sortedKeys]), encoding: .utf8
        ))
        #expect(!json.contains("occasionTime") && !json.contains("digestHorizonDays"))
        try await database.write { db in
            try db.execute(
                sql: "UPDATE Contact SET reminderWindowOverride = ? WHERE id = ?",
                arguments: [json, contact.id.uuidString]
            )
        }
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
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 23, minute: 59))],
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
                reminders: environment.reminders, contacts: environment.contacts, clock: { now }
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
