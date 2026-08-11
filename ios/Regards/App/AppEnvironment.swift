import Foundation

/// Bundle of repositories the UI layer needs. Injected at the root view so
/// swapping mock ↔ GRDB-backed repos is a one-line change at @main.
public struct AppEnvironment: Sendable {
    public let contacts: any ContactRepository
    public let groups: any ContactGroupRepository
    public let reminders: any ReminderRepository
    public let interactions: any InteractionRepository
    public let window: any ReminderWindowRepository
    public let profile: any UserProfileRepository

    public init(
        contacts: any ContactRepository,
        groups: any ContactGroupRepository,
        reminders: any ReminderRepository,
        interactions: any InteractionRepository,
        window: any ReminderWindowRepository,
        profile: any UserProfileRepository
    ) {
        self.contacts = contacts
        self.groups = groups
        self.reminders = reminders
        self.interactions = interactions
        self.window = window
        self.profile = profile
    }

    /// Phase 0 default — MockRepositories seeded with the JSX cast. Used by
    /// SwiftUI `#Preview` blocks and unit tests that need populated screens.
    public static func makeMock(
        now: Date = MockRepositories.defaultNow,
        window: ReminderWindow = MockRepositories.defaultWindow,
        includeDuplicateFixture: Bool = false,
        seedCorruptRow: Bool = false
    ) -> AppEnvironment {
        let mocks = MockRepositories(
            now: now,
            window: window,
            includeDuplicateFixture: includeDuplicateFixture,
            seedCorruptRow: seedCorruptRow
        )
        return AppEnvironment(
            contacts: mocks.contacts,
            groups: mocks.groups,
            reminders: mocks.reminders,
            interactions: mocks.interactions,
            window: mocks.window,
            profile: mocks.profile
        )
    }
}

/// Complete root composition. Repositories and every time-derived screen use
/// the same clock, while scheduling uses the persisted window timezone and
/// user-facing elapsed-day labels use the device calendar. That preserves the
/// intentional user-local versus scheduling-timezone split documented by the
/// Overdue and Contact Detail view models.
public struct AppRuntime: Sendable {
    public let environment: AppEnvironment
    public let window: ReminderWindow
    public let userCalendar: Calendar
    public let clock: @Sendable () -> Date
    /// The single `SchedulingPass` writer for this runtime (decision #36).
    /// This §14 PR22 stub only needs `reminders` + `clock`; composed here,
    /// alongside `environment`, so every screen shares the same instance.
    public let scheduler: SchedulingPass

    public init(
        environment: AppEnvironment,
        window: ReminderWindow,
        userCalendar: Calendar,
        clock: @escaping @Sendable () -> Date
    ) {
        self.environment = environment
        self.window = window
        self.userCalendar = userCalendar
        self.clock = clock
        self.scheduler = SchedulingPass(reminders: environment.reminders, clock: clock)
    }

    /// The frozen mock fixture is reserved for previews and explicit DEBUG
    /// launch arguments. Production launch always uses `makeProduction`.
    public static func makeMock(
        includeDuplicateFixture: Bool = false,
        seedCorruptRow: Bool = false
    ) -> AppRuntime {
        let now = MockRepositories.defaultNow
        let window = MockRepositories.defaultWindow
        return AppRuntime(
            environment: .makeMock(
                now: now,
                window: window,
                includeDuplicateFixture: includeDuplicateFixture,
                seedCorruptRow: seedCorruptRow
            ),
            window: window,
            userCalendar: calendar(for: .current),
            clock: { now }
        )
    }

    /// Loads the authoritative local singleton for the launch snapshot.
    /// Missing or invalid persisted state is deliberately thrown to the TF-02
    /// launch coordinator instead of silently restoring defaults. TF-05 owns
    /// rebuilding observable screen state after a saved window edit.
    public static func makeProduction(environment: AppEnvironment) async throws -> AppRuntime {
        let window = try await environment.window.fetchGlobal()
        return AppRuntime(
            environment: environment,
            window: window,
            userCalendar: calendar(for: .current),
            clock: { Date() }
        )
    }

    private static func calendar(for timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
