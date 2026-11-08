import Foundation
import GRDB
import Testing
@testable import Regards

/// `ReminderRepository.fetchSchedule()` (R66, ARCHITECTURE.md §9a): the
/// one-shot read `SchedulingPass` uses instead of subscribing to
/// `observeSchedule()`. It must return what the first observation emits,
/// and where the observation finishes with no value it must throw. Shares
/// `RepositoriesTests.swift`'s `RepositoryContractBackend` /
/// `contractContact` / `contractUUID` helpers.
@Suite(.timeLimit(.minutes(1)))
struct ScheduleFetchContractTests {

    @Test(
        "fetchSchedule returns the snapshot observeSchedule emits first",
        arguments: RepositoryContractBackend.allCases
    )
    func fetchScheduleMatchesFirstObservedSnapshot(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        // Every case the snapshot filters on is seeded, so equal values mean
        // equal filtering, ordering and window, not two empty snapshots.
        let tracked = contractContact(id: try contractUUID(1_601), suffix: "fetch-tracked", tracked: true)
        let second = contractContact(id: try contractUUID(1_602), suffix: "fetch-second", tracked: true)
        let untracked = contractContact(id: try contractUUID(1_603), suffix: "fetch-untracked")
        let archived = contractContact(
            id: try contractUUID(1_604), suffix: "fetch-archived", tracked: true,
            archivedAt: Date(timeIntervalSince1970: 1_800_000_000))
        for contact in [tracked, second, untracked, archived] {
            try await repositories.contacts.upsert(contact)
        }
        let rows = try [
            Self.row(1_611, tracked, .cadence, state: .pending, offset: 300, snoozed: true),
            Self.row(1_612, tracked, .birthday, state: .fired, offset: 100, cycle: true),
            Self.row(1_613, second, .cadence, state: .cancelled, offset: 200),
            Self.row(1_614, second, .anniversary, state: .userCaughtUp, offset: 250),
            Self.row(1_615, untracked, .cadence, state: .pending, offset: 150),
            Self.row(1_616, archived, .cadence, state: .pending, offset: 175),
        ]
        for row in rows { try await repositories.reminders.upsert(row) }
        let current = try await repositories.window.fetchGlobal()
        try await repositories.window.saveGlobal(ReminderWindow(
            allowedDays: .weekends,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 10))],
            timezoneIdentifier: "Etc/UTC",
            occasionTime: current.occasionTime))

        var iterator = await repositories.reminders.observeSchedule().makeAsyncIterator()
        let observed = try #require(await iterator.next())
        let fetched = try await repositories.reminders.fetchSchedule()

        #expect(fetched == observed)
        #expect(fetched.window.allowedDays == .weekends)
        #expect(Set(fetched.contacts.map(\.id)).isSuperset(of: [tracked.id, second.id]))
        #expect(Set(fetched.contacts.map(\.id)).isDisjoint(with: [untracked.id, archived.id]))
        #expect(try Set(fetched.reminders.map(\.id)).isSuperset(of: [contractUUID(1_611), contractUUID(1_612)]))
        #expect(try Set(fetched.reminders.map(\.id)).isDisjoint(
            with: [contractUUID(1_613), contractUUID(1_614), contractUUID(1_615), contractUUID(1_616)]))
        // The snapshot carries the cycle itself, not just two equal snapshots (a dropped field would be equal).
        let firedRowID = try contractUUID(1_612)
        #expect(fetched.reminders.first { $0.id == firedRowID }?.firedCycle
                == Date(timeIntervalSince1970: 1_799_999_980))
    }

    /// The observation finishes with no value when the window row is missing
    /// (`ScheduleObservationSnapshotContractTests`); a one-shot read has no
    /// stream to finish, so it throws and the pass run fails instead of
    /// planning from nothing.
    @Test("GRDB fetchSchedule throws when the window row is missing")
    func fetchScheduleThrowsWithoutWindowRow() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabase()
        let repositories = GRDBRepositories(dbQueue: queue)
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM ReminderWindow")
        }

        await #expect(throws: DataError.notFound) {
            _ = try await repositories.reminders.fetchSchedule()
        }
    }

    /// A row for `contact` at a fixed base time plus `offset` seconds, so the
    /// snapshot's `scheduledFor` order is the offsets' order. `snoozed` sets a
    /// floor 60 seconds before the row, and `cycle` a `firedCycle` 120 seconds
    /// before it.
    private static func row(
        _ number: Int, _ contact: Contact, _ kind: ReminderKind,
        state: ReminderState, offset: TimeInterval, snoozed: Bool = false, cycle: Bool = false
    ) throws -> ScheduledReminder {
        let isOccasion = kind != .cadence
        let scheduledFor = Date(timeIntervalSince1970: 1_800_000_000 + offset)
        return ScheduledReminder(
            id: try contractUUID(number),
            contactId: contact.id,
            kind: kind,
            occasionDate: isOccasion ? "08-07" : nil,
            occasionLabel: isOccasion ? "Occasion" : nil,
            scheduledFor: scheduledFor,
            osNotificationId: "fetch-\(number)",
            state: state,
            snoozedUntil: snoozed ? scheduledFor.addingTimeInterval(-60) : nil,
            firedCycle: cycle ? scheduledFor.addingTimeInterval(-120) : nil
        )
    }
}
