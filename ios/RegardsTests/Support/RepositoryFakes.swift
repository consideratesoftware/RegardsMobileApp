import Foundation
@testable import Regards

/// Shared in-memory repository fakes for unit tests.
///
/// These replace the per-file `Boundary*`/`Static*` copies that had drifted
/// into method-for-method duplicates (TF-01 hygiene). One fake per protocol,
/// each able to serve a fixed dataset or fail every read, so failure paths are
/// as cheap to drive as success paths.

/// The error a failing fake throws. Deliberately opaque: call sites assert on
/// the view model's resulting state, never on the error's identity.
struct RepositoryFakeFailure: Error, Equatable {}

actor StubContactRepository: ContactRepository {
    private var contacts: [Contact]
    private let failure: RepositoryFakeFailure?
    /// Independent of `failure`: lets a test make `fetch` succeed and only
    /// `upsert` fail, to exercise a write that fails *after* an earlier read
    /// (or an earlier write to a different repository) already succeeded —
    /// `failure` alone can't isolate that, since it applies uniformly to
    /// every method.
    private let upsertFailure: RepositoryFakeFailure?
    private var trackedObservers: [UUID: AsyncStream<[Contact]>.Continuation] = [:]

    init(
        _ contacts: [Contact] = [],
        failure: RepositoryFakeFailure? = nil,
        upsertFailure: RepositoryFakeFailure? = nil
    ) {
        self.contacts = contacts
        self.failure = failure
        self.upsertFailure = upsertFailure
    }

    /// A repository whose every read throws.
    static func failing(_ contacts: [Contact] = []) -> StubContactRepository {
        StubContactRepository(contacts, failure: RepositoryFakeFailure())
    }

    /// Reads succeed normally; only `upsert` fails.
    static func failingUpsert(_ contacts: [Contact] = []) -> StubContactRepository {
        StubContactRepository(contacts, upsertFailure: RepositoryFakeFailure())
    }

    private func requireSuccess() throws {
        if let failure { throw failure }
    }

    func fetchAll() async throws -> [Contact] {
        try requireSuccess()
        return contacts
    }

    /// Mirrors both production implementations: `tracked == true` **and**
    /// `archivedAt == nil`. The GRDB repository filters on both columns and
    /// `MockStore.tracked()` does the same. Filtering on `tracked` alone here
    /// would let an archived-but-tracked contact keep rows in every
    /// fake-driven test — exactly the mock/production drift R23 exists to
    /// prevent, and this fake now backs the whole Upcoming suite.
    func fetchTracked() async throws -> [Contact] {
        try requireSuccess()
        return contacts.filter { $0.tracked && $0.archivedAt == nil }
    }

    func fetch(id: UUID) async throws -> Contact? {
        try requireSuccess()
        return contacts.first { $0.id == id }
    }

    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        try requireSuccess()
        return contacts.filter { $0.contactGroupId == groupId }
    }

    /// Applies the write in-memory (mirrors both production implementations,
    /// which are real upserts) so an action test can `fetch` the contact back
    /// afterward and see `lastInteractedAt` moved.
    func upsert(_ contact: Contact) async throws {
        try requireSuccess()
        if let upsertFailure { throw upsertFailure }
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
        broadcastTrackedChange()
    }

    func archive(id: UUID, at: Date) async throws {
        try requireSuccess()
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].archivedAt = at
        broadcastTrackedChange()
    }

    func storedCount() -> Int { contacts.count }

    private var subscribeCount = 0

    /// Test-only instrumentation: how many times `observeTracked()` has been
    /// called, i.e. how many independent subscriptions exist. A view model
    /// that subscribes once per `load()` instead of once ever would show up
    /// here as `> 1` after two concurrent `load()` calls.
    func subscriptionCount() -> Int { subscribeCount }

    /// A real live stream (mirrors `GRDBContactRepository`/`MockStore`), for
    /// tests that assert an Overdue/Upcoming view model reflects a write made
    /// through a *different* repository reference to the same fake.
    /// Never replays the current value on subscribe — only a write *after*
    /// subscribing reaches the stream, matching the mock/GRDB contract (see
    /// `ContactRepository.observeTracked()`'s doc comment). Registers the
    /// continuation synchronously via `AsyncStream.makeStream` rather than
    /// inside the closure-based initializer, so there's no window where a
    /// write landing right after subscribe is missed (mirrors
    /// `MockStore.observeTracked()`).
    func observeTracked() async -> AsyncStream<[Contact]> {
        subscribeCount += 1
        let (stream, continuation) = AsyncStream.makeStream(of: [Contact].self)
        let token = UUID()
        trackedObservers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeTrackedObserver(token) }
        }
        return stream
    }

    private func removeTrackedObserver(_ token: UUID) {
        trackedObservers.removeValue(forKey: token)
    }

    private func broadcastTrackedChange() {
        let current = contacts.filter { $0.tracked && $0.archivedAt == nil }
        for continuation in trackedObservers.values {
            continuation.yield(current)
        }
    }
}

/// A `ContactRepository` whose backing `ContactFetchReport` (healthy
/// contacts plus corruption diagnostics) can be replaced after
/// construction — for tests that mutate the store mid-test to simulate
/// what a completed reconciliation pass, a newly-discovered corrupt row, or
/// a fresh import would produce, then assert a view model or screen reacts
/// through its real observation path rather than a direct reload call. A
/// fixed report that's never replaced works too (just don't call
/// `setReport`/`replaceContacts`), so this also covers what a `Stub`-style
/// fixed fake would have needed. Consolidates three near-identical
/// single-call-site fakes (`MutableAllContactsRepository`,
/// `MutableDiagnosticsRepository`, `FixedDiagnosticsRepository`) that had
/// accumulated one per test file across TF-03.
actor SettableContactRepository: ContactRepository {
    private var report: ContactFetchReport

    init(contacts: [Contact] = [], corrupted: [ContactCorruptionDiagnostic] = []) {
        self.report = ContactFetchReport(contacts: contacts, corrupted: corrupted)
    }

    init(report: ContactFetchReport) {
        self.report = report
    }

    func fetchAll() async throws -> [Contact] { report.contacts }
    func fetchTracked() async throws -> [Contact] {
        report.contacts.filter { $0.tracked && $0.isActive }
    }
    func fetch(id: UUID) async throws -> Contact? { report.contacts.first { $0.id == id } }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        report.contacts.filter { $0.contactGroupId == groupId }
    }
    func upsert(_ contact: Contact) async throws {
        report = ContactFetchReport(contacts: report.contacts + [contact], corrupted: report.corrupted)
    }
    func archive(id: UUID, at: Date) async throws {}
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport { report }

    /// Replaces the healthy contacts, leaving the current corruption
    /// diagnostics untouched.
    func replaceContacts(_ newContacts: [Contact]) {
        report = ContactFetchReport(contacts: newContacts, corrupted: report.corrupted)
    }

    /// Replaces the entire report — contacts and diagnostics both.
    func setReport(_ newReport: ContactFetchReport) {
        report = newReport
    }
}

actor StubReminderRepository: ReminderRepository {
    private var reminders: [ScheduledReminder]
    private let failure: RepositoryFakeFailure?
    /// Independent of `failure`: lets a test make reads succeed and only
    /// `upsert` fail — e.g. `OverdueViewModel.snooze`'s failure path re-reads
    /// through the same `reminders` reference `SchedulingPass.snooze` writes
    /// through, so making the whole repository fail would fail the *restore*
    /// read too, not just the write under test.
    private let upsertFailure: RepositoryFakeFailure?

    init(
        _ reminders: [ScheduledReminder] = [],
        failure: RepositoryFakeFailure? = nil,
        upsertFailure: RepositoryFakeFailure? = nil
    ) {
        self.reminders = reminders
        self.failure = failure
        self.upsertFailure = upsertFailure
    }

    /// A repository whose every read throws.
    static func failing() -> StubReminderRepository {
        StubReminderRepository([], failure: RepositoryFakeFailure())
    }

    /// Reads succeed normally; only `upsert` fails.
    static func failingUpsert() -> StubReminderRepository {
        StubReminderRepository([], upsertFailure: RepositoryFakeFailure())
    }

    private func requireSuccess() throws {
        if let failure { throw failure }
    }

    /// Mirrors both production implementations, which filter on
    /// `state == .pending`. Returning every reminder regardless of state would
    /// let a fired, cancelled, or caught-up reminder keep a row in Upcoming
    /// throughout the fake-driven suite while production quietly excludes it
    /// (R23 mock/production drift).
    func fetchAllPending() async throws -> [ScheduledReminder] {
        try requireSuccess()
        return reminders.filter { $0.state == .pending }
    }

    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder] {
        try requireSuccess()
        return reminders.filter { $0.contactId == contactId && $0.state == .pending }
    }

    /// Applies the write in-memory (mirrors both production
    /// implementations), so a `SchedulingPass.snooze` write-then-read
    /// round trip is actually observable — see `StubContactRepository`'s
    /// sibling note.
    func upsert(_ reminder: ScheduledReminder) async throws {
        try requireSuccess()
        if let upsertFailure { throw upsertFailure }
        if let index = reminders.firstIndex(where: { $0.id == reminder.id }) {
            reminders[index] = reminder
        } else {
            reminders.append(reminder)
        }
    }

    func updateState(id: UUID, state: ReminderState) async throws {
        try requireSuccess()
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].state = state
    }

    func delete(id: UUID) async throws {
        try requireSuccess()
        reminders.removeAll { $0.id == id }
    }
}

actor StubInteractionRepository: InteractionRepository {
    private var logs: [InteractionLog]
    private let failure: RepositoryFakeFailure?

    init(_ logs: [InteractionLog] = [], failure: RepositoryFakeFailure? = nil) {
        self.logs = logs
        self.failure = failure
    }

    /// A repository whose every call throws.
    static func failing() -> StubInteractionRepository {
        StubInteractionRepository(failure: RepositoryFakeFailure())
    }

    private func requireSuccess() throws {
        if let failure { throw failure }
    }

    /// Mirrors both production implementations: ordered by `occurredAt`
    /// descending then `id` ascending, and `limit <= 0` returns empty.
    func fetchRecent(forContact contactId: UUID, limit: Int) async throws -> [InteractionLog] {
        try requireSuccess()
        guard limit > 0 else { return [] }
        return logs
            .filter { $0.contactId == contactId }
            .sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(limit)
            .map { $0 }
    }

    func append(_ log: InteractionLog) async throws {
        try requireSuccess()
        logs.append(log)
    }

    /// Test-only inspection of every logged interaction, in append order.
    func appendedLogs() -> [InteractionLog] { logs }
}

struct StubReminderWindowRepository: ReminderWindowRepository {
    enum ReadFailure: Sendable {
        case opaque
        case missing
        case invalidTimezone(String)
    }

    let failure: ReadFailure

    static func failing() -> StubReminderWindowRepository {
        StubReminderWindowRepository(failure: .opaque)
    }

    static func missing() -> StubReminderWindowRepository {
        StubReminderWindowRepository(failure: .missing)
    }

    static func invalidTimezone(_ identifier: String) -> StubReminderWindowRepository {
        StubReminderWindowRepository(failure: .invalidTimezone(identifier))
    }

    func fetchGlobal() async throws -> ReminderWindow {
        switch failure {
        case .opaque:
            throw RepositoryFakeFailure()
        case .missing:
            throw DataError.notFound
        case let .invalidTimezone(identifier):
            throw ReminderWindow.ValidationError.invalidTimezoneIdentifier(identifier)
        }
    }

    func saveGlobal(_ window: ReminderWindow) async throws {}
}
