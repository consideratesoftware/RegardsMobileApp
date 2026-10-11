import Foundation
@testable import Regards

/// Shared world for the reminder-window editor suites. The stored values are
/// deliberately not the app defaults (zone, horizon, occasion time, days), so
/// a save that leaks into, resets, or rewrites a field it must not touch shows
/// up as a difference instead of matching by coincidence.
@MainActor
enum ReminderWindowEditorFixtures {

    /// Fri 2027-01-15 08:00 UTC.
    static let now = UpcomingFixtures.now

    /// Mon to Sat, two ranges, wrapping quiet hours, Lord Howe, 30-day horizon,
    /// 07:15 occasion time.
    static let storedGlobal = ReminderWindow(
        allowedDays: [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday],
        allowedTimeRanges: [
            TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12)),
            TimeRange(start: TimeOfDay(hour: 14), end: TimeOfDay(hour: 16)),
        ],
        quietHours: TimeRange(start: TimeOfDay(hour: 21), end: TimeOfDay(hour: 6)),
        timezoneIdentifier: "Australia/Lord_Howe",
        occasionTime: TimeOfDay(hour: 7, minute: 15),
        digestHorizonDays: 30
    )

    /// A bystander's override, different from `storedGlobal` in every field.
    static let bystanderOverride = ReminderWindow(
        allowedDays: .sunday,
        allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 9))],
        timezoneIdentifier: "Pacific/Kiritimati",
        occasionTime: TimeOfDay(hour: 5, minute: 30),
        digestHorizonDays: 7
    )

    /// Everything an editor save could touch, read back from the repositories.
    struct StoreSnapshot: Equatable {
        let global: ReminderWindow
        let target: Contact?
        let bystander: Contact?
    }

    struct World {
        let environment: AppEnvironment
        let target: Contact
        let bystander: Contact

        func snapshot() async throws -> StoreSnapshot {
            try await Self.snapshot(
                window: environment.window,
                contacts: environment.contacts,
                targetID: target.id,
                bystanderID: bystander.id
            )
        }

        static func snapshot(
            window: any ReminderWindowRepository,
            contacts: any ContactRepository,
            targetID: UUID,
            bystanderID: UUID
        ) async throws -> StoreSnapshot {
            StoreSnapshot(
                global: try await window.fetchGlobal(),
                target: try await contacts.fetch(id: targetID),
                bystander: try await contacts.fetch(id: bystanderID)
            )
        }
    }

    /// In-memory GRDB with `global` stored, a tracked target contact without an
    /// override, and a tracked bystander with `bystanderOverride`.
    static func makeWorld(
        global: ReminderWindow = storedGlobal,
        targetOverride: ReminderWindow? = nil
    ) async throws -> World {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.window.saveGlobal(global)
        let target = UpcomingFixtures.contact(
            systemRef: "editor-target", displayName: "Target", cadenceDays: 7,
            reminderWindowOverride: targetOverride
        )
        let bystander = UpcomingFixtures.contact(
            systemRef: "editor-bystander", displayName: "Bystander", cadenceDays: 7,
            reminderWindowOverride: bystanderOverride
        )
        try await environment.contacts.upsert(target)
        try await environment.contacts.upsert(bystander)
        return World(environment: environment, target: target, bystander: bystander)
    }

    /// Records every window passed to `onSaved`.
    @MainActor
    final class SaveRecorder {
        private(set) var windows: [ReminderWindow] = []
        func record(_ window: ReminderWindow) { windows.append(window) }
    }

    static func editor(
        _ target: ReminderWindowsViewModel.Target,
        contacts: any ContactRepository,
        window: any ReminderWindowRepository,
        recorder: SaveRecorder,
        now: Date = ReminderWindowEditorFixtures.now
    ) -> ReminderWindowsViewModel {
        ReminderWindowsViewModel(
            target: target,
            window: window,
            contacts: contacts,
            clock: { now },
            onSaved: { recorder.record($0) }
        )
    }

    static func editor(
        _ target: ReminderWindowsViewModel.Target,
        world: World,
        recorder: SaveRecorder,
        now: Date = ReminderWindowEditorFixtures.now
    ) -> ReminderWindowsViewModel {
        editor(target, contacts: world.environment.contacts, window: world.environment.window,
               recorder: recorder, now: now)
    }
}

/// Reads delegate to `wrapped`; `saveGlobal` always throws.
struct ThrowingSaveWindowRepository: ReminderWindowRepository {
    let wrapped: any ReminderWindowRepository
    func fetchGlobal() async throws -> ReminderWindow { try await wrapped.fetchGlobal() }
    func saveGlobal(_ window: ReminderWindow) async throws { throw RepositoryFakeFailure() }
}
