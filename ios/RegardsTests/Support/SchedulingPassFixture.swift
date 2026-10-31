import Foundation
import Testing
@testable import Regards

// MARK: - Counting repository

/// A `ReminderRepository` that forwards every call to a real backend and
/// counts the writes, so a test can prove a pass run changed nothing.
/// `observeSchedule()` forwards too: the pass reads its snapshot from it.
/// `upsertGate`, when set, holds the first `upsert` open until the gate opens:
/// the run has read its snapshot and decided, and is parked before writing.
actor CountingReminderRepository: ReminderRepository {
    private let wrapped: any ReminderRepository
    private var upsertGate: AsyncGate?
    private(set) var upserts = 0
    private(set) var transitions = 0
    private(set) var stateUpdates = 0
    private(set) var deletes = 0

    init(_ wrapped: any ReminderRepository, upsertGate: AsyncGate? = nil) {
        self.wrapped = wrapped
        self.upsertGate = upsertGate
    }

    /// Every write of any kind since construction.
    var writeCount: Int { upserts + transitions + stateUpdates + deletes }

    func fetchAllPending() async throws -> [ScheduledReminder] { try await wrapped.fetchAllPending() }

    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder] {
        try await wrapped.fetchPending(forContact: contactId)
    }

    func upsert(_ reminder: ScheduledReminder) async throws {
        upserts += 1
        if let gate = upsertGate {
            upsertGate = nil
            await gate.wait()
        }
        try await wrapped.upsert(reminder)
    }

    func updateState(id: UUID, state: ReminderState) async throws {
        stateUpdates += 1
        try await wrapped.updateState(id: id, state: state)
    }

    @discardableResult
    func transitionState(id: UUID, from: ReminderState, to: ReminderState) async throws -> Bool {
        transitions += 1
        return try await wrapped.transitionState(id: id, from: from, to: to)
    }

    func delete(id: UUID) async throws {
        deletes += 1
        try await wrapped.delete(id: id)
    }

    func observeSchedule() async -> AsyncStream<ScheduleSnapshot> {
        await wrapped.observeSchedule()
    }
}

// MARK: - Pass fixture

/// One `SchedulingPass` over a real backend (GRDB or the seeded mock), a
/// movable clock, and America/New_York windows, so a test reads as dates and
/// slots. The default global window is every day 18:00-19:00 with no quiet
/// hours: a slot opens at 18:00 local each day, and occasions fire at the
/// default 09:00.
///
/// The mock backend carries its seed cast, which the pass schedules too, so
/// assertions look rows up by the test's own contact ids.
struct PassFixture {
    static let zone = "America/New_York"

    let repositories: RepositoryContractRepositories
    let reminders: CountingReminderRepository
    let clock: MutableClock
    let pass: SchedulingPass

    init(
        backend: RepositoryContractBackend,
        now: String = "2026-06-10 10:00",
        window: ReminderWindow = PassFixture.eveningWindow(),
        occasions: @escaping @Sendable ([Contact]) async -> [ContactOccasion] = { _ in [] },
        upsertGate: AsyncGate? = nil
    ) async throws {
        let repositories = try backend.makeRepositories()
        try await repositories.window.saveGlobal(window)
        let clock = MutableClock(Self.at(now))
        let reminders = CountingReminderRepository(repositories.reminders, upsertGate: upsertGate)
        self.repositories = repositories
        self.reminders = reminders
        self.clock = clock
        self.pass = SchedulingPass(
            reminders: reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            occasions: occasions,
            clock: { clock.now() }
        )
    }

    /// "yyyy-MM-dd HH:mm" in New York.
    static func at(_ local: String) -> Date {
        EngineFixtures.date(local, tz: zone)
    }

    static func eveningWindow(
        days: DayOfWeekMask = .allDays,
        start: Int = 18,
        end: Int = 19,
        quiet: TimeRange? = nil,
        zone: String = PassFixture.zone,
        occasionTime: TimeOfDay = ReminderWindow.defaultOccasionTime
    ) -> ReminderWindow {
        ReminderWindow(
            allowedDays: days,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: start), end: TimeOfDay(hour: end))],
            quietHours: quiet,
            timezoneIdentifier: zone,
            occasionTime: occasionTime
        )
    }

    /// A tracked contact with a cadence. `lastInteracted` and `createdAt`
    /// are New York local times.
    func addContact(
        _ number: Int,
        cadenceDays: Int? = 7,
        lastInteracted: String? = "2026-05-01 10:00",
        override: ReminderWindow? = nil,
        tracked: Bool = true,
        archivedAt: Date? = nil
    ) async throws -> Contact {
        let contact = Contact(
            id: try contractUUID(7_000 + number),
            systemContactRef: "pass-\(number)",
            displayName: "Pass \(number)",
            tracked: tracked,
            cadenceDays: cadenceDays,
            reminderWindowOverride: override,
            lastInteractedAt: lastInteracted.map(Self.at),
            createdAt: Self.at("2026-01-01 10:00"),
            archivedAt: archivedAt
        )
        try await repositories.contacts.upsert(contact)
        return contact
    }

    /// The contact's pending cadence row, if any.
    func cadenceRow(_ contact: Contact) async throws -> ScheduledReminder? {
        try await repositories.reminders.fetchPending(forContact: contact.id).first { $0.kind == .cadence }
    }

    /// The contact's pending row of an occasion kind, if any.
    func occasionRow(_ contact: Contact, _ kind: ReminderKind) async throws -> ScheduledReminder? {
        try await repositories.reminders.fetchPending(forContact: contact.id).first { $0.kind == kind }
    }

    /// A pending or fired row by id, as the pass sees it (`observeSchedule`).
    /// `fetchPending` cannot return a fired row.
    func row(_ id: UUID) async throws -> ScheduledReminder? {
        for await snapshot in await repositories.reminders.observeSchedule() {
            return snapshot.reminders.first { $0.id == id }
        }
        return nil
    }

    func cadenceID(_ contact: Contact) -> UUID {
        SchedulingPass.reminderID(contactId: contact.id, kind: .cadence)
    }

    func setNow(_ local: String) {
        setNow(Self.at(local))
    }

    func setNow(_ date: Date) {
        clock.advance(by: date.timeIntervalSince(clock.now()))
    }
}

// MARK: - Mock runtime and view-model helpers

extension MockRepositories {
    /// A pass over the seed cast with the mock occasion provider, as the mock
    /// runtime composes it. The store itself seeds no occasion rows, so
    /// `runFull()` is what gives the seed cast its birthday and anniversary.
    func occasionPass(now: Date, window: ReminderWindow = MockRepositories.defaultWindow) -> SchedulingPass {
        SchedulingPass(
            reminders: reminders,
            contacts: contacts,
            window: self.window,
            occasions: MockRepositories.occasionProvider(now: now, window: window),
            clock: { now }
        )
    }
}

/// The pass the view-model tests hand a screen: no occasions and an every-day,
/// all-day window in America/Los_Angeles (`FixedReminderWindowRepository`'s
/// default), so Snooze lands on the first local midnight at or after its floor.
func makeScheduler(
    reminders: any ReminderRepository,
    contacts: any ContactRepository,
    clock: @escaping @Sendable () -> Date
) -> SchedulingPass {
    SchedulingPass(
        reminders: reminders,
        contacts: contacts,
        window: FixedReminderWindowRepository(),
        occasions: { _ in [] },
        clock: clock
    )
}
