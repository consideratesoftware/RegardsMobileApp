import Foundation
import Testing
@testable import Regards

/// `ReminderRepository.observeSchedule()` mock/GRDB contract parity
/// (ARCHITECTURE.md §9, §14 PR25, R10). One read returns the tracked
/// contacts, their pending and fired reminders, and the global window, so
/// Overdue, Upcoming, and the labels all see the same snapshot. Shares
/// `RepositoriesTests.swift`'s `RepositoryContractBackend` /
/// `contractContact` / `contractUUID` helpers.
///
/// Unlike `observeTracked()`, the stream emits the current snapshot on
/// subscribe, so a screen needs no separate `load()` to start.
@Suite(.timeLimit(.minutes(1)))
struct ScheduleObservationContractTests {

    @Test(
        "observeSchedule emits the current snapshot on subscribe, then again after a reminder write",
        arguments: RepositoryContractBackend.allCases
    )
    func observeScheduleEmitsInitialAndAfterReminderWrite(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(601), suffix: "schedule-initial", tracked: true)
        let first = ScheduledReminder(
            id: try contractUUID(602),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_100),
            osNotificationId: "schedule-initial-first"
        )
        try await repositories.contacts.upsert(contact)
        try await repositories.reminders.upsert(first)

        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()

        // No write has happened since subscribing, so this is the replay.
        let initial = try #require(await iterator.next())
        #expect(initial.contacts.map(\.id).contains(contact.id))
        #expect(initial.reminders.map(\.id).contains(first.id))

        let second = ScheduledReminder(
            id: try contractUUID(603),
            contactId: contact.id,
            kind: .birthday,
            occasionDate: "08-07",
            occasionLabel: "Birthday",
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_200),
            osNotificationId: "schedule-initial-second"
        )
        try await repositories.reminders.upsert(second)

        let afterWrite = try #require(await iterator.next())
        #expect(Set(afterWrite.reminders.map(\.id)).isSuperset(of: [first.id, second.id]))
    }

    @Test(
        "observeSchedule drops a contact and its reminder rows together when the contact is untracked",
        arguments: RepositoryContractBackend.allCases
    )
    func observeScheduleExcludesUntrackedInSameRead(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contactID = try contractUUID(611)
        let reminder = ScheduledReminder(
            id: try contractUUID(612),
            contactId: contactID,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_100),
            osNotificationId: "schedule-untracked"
        )
        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "schedule-untracked", tracked: true))
        try await repositories.reminders.upsert(reminder)

        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.contacts.map(\.id).contains(contactID))
        #expect(initial.reminders.map(\.id).contains(reminder.id))

        // One Contact write, no ScheduledReminder write: the emitted
        // snapshot must already omit the row, not leave it for the reader to
        // filter against a contact list from another read.
        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "schedule-untracked", tracked: false))

        let afterUntrack = try #require(await iterator.next())
        #expect(!afterUntrack.contacts.map(\.id).contains(contactID))
        #expect(!afterUntrack.reminders.map(\.contactId).contains(contactID))
    }

    @Test(
        "observeSchedule omits an archived contact and its reminder rows",
        arguments: RepositoryContractBackend.allCases
    )
    func observeScheduleExcludesArchived(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contactID = try contractUUID(621)
        let reminder = ScheduledReminder(
            id: try contractUUID(622),
            contactId: contactID,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_100),
            osNotificationId: "schedule-archived"
        )
        try await repositories.contacts.upsert(
            contractContact(id: contactID, suffix: "schedule-archived", tracked: true))
        try await repositories.reminders.upsert(reminder)

        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()
        _ = try #require(await iterator.next())

        try await repositories.contacts.upsert(
            contractContact(
                id: contactID, suffix: "schedule-archived", tracked: true,
                archivedAt: Date(timeIntervalSince1970: 1_800_000_000)))

        let afterArchive = try #require(await iterator.next())
        #expect(!afterArchive.contacts.map(\.id).contains(contactID))
        #expect(!afterArchive.reminders.map(\.contactId).contains(contactID))
    }

    @Test(
        "observeSchedule carries pending and fired rows, and leaves out cancelled and caught-up rows",
        arguments: RepositoryContractBackend.allCases
    )
    func observeScheduleCarriesPendingAndFiredOnly(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(631), suffix: "schedule-states", tracked: true)
        try await repositories.contacts.upsert(contact)
        var rows: [ReminderState: ScheduledReminder] = [:]
        for (offset, state) in ReminderState.allCases.enumerated() {
            let row = ScheduledReminder(
                id: try contractUUID(640 + offset),
                contactId: contact.id,
                kind: .cadence,
                scheduledFor: Date(timeIntervalSince1970: 1_800_000_100 + TimeInterval(offset)),
                osNotificationId: "schedule-states-\(state.rawValue)",
                state: state
            )
            rows[state] = row
            try await repositories.reminders.upsert(row)
        }

        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()
        let snapshot = try #require(await iterator.next())

        let ids = Set(snapshot.reminders.map(\.id))
        #expect(ids.contains(try #require(rows[.pending]).id))
        #expect(ids.contains(try #require(rows[.fired]).id))
        #expect(!ids.contains(try #require(rows[.cancelled]).id))
        #expect(!ids.contains(try #require(rows[.userCaughtUp]).id))
    }

    @Test(
        "observeSchedule emits after each kind of reminder write",
        arguments: RepositoryContractBackend.allCases, ReminderRowWrite.allCases
    )
    func observeScheduleEmitsAfterEachReminderWrite(
        backend: RepositoryContractBackend, write: ReminderRowWrite
    ) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(671), suffix: "schedule-writes", tracked: true)
        let reminder = ScheduledReminder(
            id: try contractUUID(672),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_100),
            osNotificationId: "schedule-writes"
        )
        try await repositories.contacts.upsert(contact)
        try await repositories.reminders.upsert(reminder)
        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.reminders.first { $0.id == reminder.id }?.state == .pending)

        switch write {
        case .markFired:
            try await repositories.reminders.updateState(id: reminder.id, state: .fired)
        case .transitionToCaughtUp:
            try await repositories.reminders.transitionState(
                id: reminder.id, from: .pending, to: .userCaughtUp)
        case .delete:
            try await repositories.reminders.delete(id: reminder.id)
        }

        let afterWrite = try #require(await iterator.next())
        let row = afterWrite.reminders.first { $0.id == reminder.id }
        switch write {
        case .markFired:
            #expect(row?.state == .fired)
        case .transitionToCaughtUp, .delete:
            #expect(row == nil)
        }
    }

    @Test(
        "observeSchedule emits after the global window is saved",
        arguments: RepositoryContractBackend.allCases
    )
    func observeScheduleEmitsAfterGlobalWindowSave(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let current = try await repositories.window.fetchGlobal()
        let edited = ReminderWindow(
            allowedDays: current.allowedDays,
            allowedTimeRanges: current.allowedTimeRanges,
            quietHours: current.quietHours,
            timezoneIdentifier: current.timezoneIdentifier,
            occasionTime: current.occasionTime,
            digestHorizonDays: current.digestHorizonDays == 30 ? 7 : 30
        )
        let stream = await repositories.reminders.observeSchedule()
        var iterator = stream.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.window == current)

        try await repositories.window.saveGlobal(edited)

        let afterSave = try #require(await iterator.next())
        #expect(afterSave.window == edited)
    }

    /// A write that leaves the snapshot equal must behave the same on both
    /// backends: `observeSchedule()` yields nothing for it. This is the rule
    /// R61 (d) wants pinned for `observeTracked()`; that item stays open.
    /// GRDB notifies on any transaction that touches the observed tables, so
    /// the real backend has to drop equal values and the mock has to match.
    ///
    /// Detection needs the duplicate to reach the consumer before a later
    /// write can replace it in the newest-1 buffer. Three steps arrange that:
    /// - The test is `@MainActor` and so is the consumer task. The consumer
    ///   signals after the initial snapshot and loops back to `next()`; the
    ///   test cannot resume until the consumer suspends there. It is parked
    ///   when the no-op lands, so a duplicate resumes it directly.
    /// - After the no-op, a repository read runs before the sentinel write.
    ///   The mock yields inside the write, before it returns. GRDB's
    ///   `DatabaseQueue` runs the observation's fetch ahead of a read queued
    ///   after the commit, and delivers it to the main queue ahead of this
    ///   test's resumption. That GRDB ordering is an assumption, not
    ///   something the test proves.
    /// - The sentinel is a distinguishable write, and the consumer must see
    ///   exactly initial then sentinel, so a duplicate shows as a third
    ///   snapshot.
    /// The assumption in the second step is why the scenario repeats on
    /// fresh databases: a missed duplicate can pass a broken backend once,
    /// and `rounds` makes that unlikely. It cannot fail a correct backend.
    @Test(
        "observeSchedule emits nothing for a write that changes nothing",
        arguments: RepositoryContractBackend.allCases, NoOpScheduleWrite.allCases
    )
    @MainActor
    func observeScheduleNoOpWriteParity(
        backend: RepositoryContractBackend, write: NoOpScheduleWrite
    ) async throws {
        let rounds = 20
        for round in 0..<rounds {
            let repositories = try backend.makeRepositories()
            let contact = contractContact(id: try contractUUID(651), suffix: "schedule-noop", tracked: true)
            let reminder = ScheduledReminder(
                id: try contractUUID(652),
                contactId: contact.id,
                kind: .cadence,
                scheduledFor: Date(timeIntervalSince1970: 1_800_000_100),
                osNotificationId: "schedule-noop"
            )
            let sentinel = ScheduledReminder(
                id: try contractUUID(653),
                contactId: contact.id,
                kind: .birthday,
                occasionDate: "08-07",
                occasionLabel: "Birthday",
                scheduledFor: Date(timeIntervalSince1970: 1_800_000_200),
                osNotificationId: "schedule-noop-sentinel"
            )
            try await repositories.contacts.upsert(contact)
            try await repositories.reminders.upsert(reminder)
            let window = try await repositories.window.fetchGlobal()

            let stream = await repositories.reminders.observeSchedule()
            let (ready, signalReady) = AsyncStream.makeStream(of: Void.self)
            let sentinelID = sentinel.id
            let consumer = Task { @MainActor () -> [ScheduleSnapshot] in
                var seen: [ScheduleSnapshot] = []
                for await snapshot in stream {
                    seen.append(snapshot)
                    if seen.count == 1 { signalReady.yield() }
                    if snapshot.reminders.contains(where: { $0.id == sentinelID }) { break }
                }
                return seen
            }
            var readyIterator = ready.makeAsyncIterator()
            await readyIterator.next()

            switch write {
            case .identicalReminderUpsert:
                try await repositories.reminders.upsert(reminder)
            case .sameStateUpdate:
                try await repositories.reminders.updateState(id: reminder.id, state: .pending)
            case .identicalWindowSave:
                try await repositories.window.saveGlobal(window)
            }
            _ = try await repositories.reminders.fetchAllPending()
            try await repositories.reminders.upsert(sentinel)

            let seen = await withTaskCancellationHandler {
                await consumer.value
            } onCancel: {
                consumer.cancel()
            }
            #expect(
                seen.count == 2,
                "round \(round): got \(seen.count) snapshots; the no-op write must not add one")
            #expect(seen.first?.reminders.contains { $0.id == reminder.id } == true)
            #expect(seen.last?.reminders.contains { $0.id == sentinel.id } == true)
            if seen.count != 2 { break }
        }
    }
}

/// The writes `observeScheduleNoOpWriteParity` replays against each backend.
enum NoOpScheduleWrite: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case identicalReminderUpsert
    case sameStateUpdate
    case identicalWindowSave

    var testDescription: String { rawValue }
}

/// The reminder writes `observeScheduleEmitsAfterEachReminderWrite` replays
/// against each backend.
enum ReminderRowWrite: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case markFired
    case transitionToCaughtUp
    case delete

    var testDescription: String { rawValue }
}
