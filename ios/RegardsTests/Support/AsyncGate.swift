import Foundation
@testable import Regards

/// A manually-releasable async gate for tests that need to pause a
/// suspension point deterministically — e.g. holding a `load()` call's
/// `fetchTracked()` await open so a test can fire a row action while that
/// load is still in flight, instead of hoping a real race reproduces on a
/// given run.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiterCount = 0

    /// Suspends until `open()` is called, unless the gate is already open.
    func wait() async {
        waiterCount += 1
        let arrived = arrivalWaiters
        arrivalWaiters = []
        for continuation in arrived { continuation.resume() }
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Suspends until at least one call to `wait()` has been made — lets a
    /// test know a background `Task` has genuinely reached the gated
    /// suspension point before proceeding, instead of guessing with a
    /// `Task.yield()`.
    func waitUntilArrived() async {
        if waiterCount > 0 { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    /// Releases every call currently suspended in `wait()`, and every future
    /// one, immediately.
    func open() {
        isOpen = true
        let toResume = waiters
        waiters = []
        for continuation in toResume { continuation.resume() }
    }

    /// Resets the gate to closed and clears the arrival count, for a test
    /// that needs a second, independently-gated `wait()` round after the
    /// first has already been opened.
    func close() {
        isOpen = false
        waiterCount = 0
    }
}

/// Wraps a `ContactRepository`, delaying `fetchTracked()` specifically until
/// `gate` is opened — the one read `OverdueViewModel`/`UpcomingViewModel`'s
/// `performLoad()` awaits before checking `loadGeneration`. Every other
/// method passes straight through, so a row action's own writes (`fetch`,
/// `upsert`/`updateLastInteractedAt`) are never gated.
struct GatedFetchTrackedContactRepository: ContactRepository {
    let wrapped: any ContactRepository
    let gate: AsyncGate

    func fetchAll() async throws -> [Contact] { try await wrapped.fetchAll() }
    func fetchTracked() async throws -> [Contact] {
        await gate.wait()
        return try await wrapped.fetchTracked()
    }
    func fetch(id: UUID) async throws -> Contact? { try await wrapped.fetch(id: id) }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        try await wrapped.fetchMembers(ofGroup: groupId)
    }
    func upsert(_ contact: Contact) async throws { try await wrapped.upsert(contact) }
    func archive(id: UUID, at: Date) async throws { try await wrapped.archive(id: id, at: at) }
    func observeTracked() async -> AsyncStream<[Contact]> { await wrapped.observeTracked() }
    func updateReconciledFields(id: UUID, fields: ReconciledContactFields) async throws {
        try await wrapped.updateReconciledFields(id: id, fields: fields)
    }
    @discardableResult
    func updateLastInteractedAt(id: UUID, at date: Date) async throws -> Bool {
        try await wrapped.updateLastInteractedAt(id: id, at: date)
    }
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport {
        try await wrapped.fetchAllWithDiagnostics()
    }
}

/// Wraps a `ReminderRepository`, delaying `updateState()` specifically — the
/// call `SchedulingPass.caughtUp` makes. Pairs with
/// `GatedFetchTrackedContactRepository` in tests that need to hold
/// `markCaughtUp` open *before* it reaches its own trailing `performLoad()`
/// call: without also gating this, `markCaughtUp`'s scheduler and logging
/// writes would race ahead unblocked, reach its own `performLoad()`, and
/// self-correct before the test can observe the "flash" window the
/// `loadGeneration` bump exists to close.
struct GatedUpdateStateReminderRepository: ReminderRepository {
    let wrapped: any ReminderRepository
    let gate: AsyncGate

    func fetchAllPending() async throws -> [ScheduledReminder] { try await wrapped.fetchAllPending() }
    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder] {
        try await wrapped.fetchPending(forContact: contactId)
    }
    func upsert(_ reminder: ScheduledReminder) async throws { try await wrapped.upsert(reminder) }
    func updateState(id: UUID, state: ReminderState) async throws {
        await gate.wait()
        try await wrapped.updateState(id: id, state: state)
    }
    func delete(id: UUID) async throws { try await wrapped.delete(id: id) }
}
