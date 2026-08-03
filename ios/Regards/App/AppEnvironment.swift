import Foundation
import GRDB

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
        includeDuplicateFixture: Bool = false
    ) -> AppEnvironment {
        let mocks = MockRepositories(
            now: now,
            includeDuplicateFixture: includeDuplicateFixture
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

    /// Production wiring — every repo backed by GRDB on the supplied
    /// `DatabaseQueue`. The caller owns the queue's lifetime; production
    /// builds open it via `DatabaseFactory.makeDatabase()`, tests pass
    /// `DatabaseFactory.makeInMemoryDatabase()`.
    public static func makeProduction(database: DatabaseQueue) -> AppEnvironment {
        let repos = GRDBRepositories(dbQueue: database)
        return AppEnvironment(
            contacts: repos.contacts,
            groups: repos.groups,
            reminders: repos.reminders,
            interactions: repos.interactions,
            window: repos.window,
            profile: repos.profile
        )
    }
}
