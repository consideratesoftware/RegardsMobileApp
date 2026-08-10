import Foundation
import Testing
@testable import Regards

/// `SchedulingPass.snooze` mock/GRDB parity (ARCHITECTURE.md §14 PR22's
/// DB-only stub). Shares `RepositoriesTests.swift`'s `RepositoryContractBackend`
/// / `contractContact` / `contractUUID` helpers.
struct SchedulingPassTests {

    @Test(
        "Snooze writes a pending cadence reminder 7 days from the call's clock",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeWritesSevenDaysOut(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(501), suffix: "snooze-fresh", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { now })

        try await scheduler.snooze(contactId: contact.id)

        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].kind == .cadence)
        #expect(pending[0].state == .pending)
        #expect(pending[0].scheduledFor == now.addingTimeInterval(7 * 86_400))
    }

    @Test(
        "A second snooze replaces the pending row rather than duplicating it",
        arguments: RepositoryContractBackend.allCases
    )
    func secondSnoozeReplacesNotDuplicates(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(502), suffix: "snooze-repeat", tracked: true)
        try await repositories.contacts.upsert(contact)
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let second = first.addingTimeInterval(3 * 86_400)

        try await SchedulingPass(reminders: repositories.reminders, clock: { first }).snooze(contactId: contact.id)
        try await SchedulingPass(reminders: repositories.reminders, clock: { second }).snooze(contactId: contact.id)

        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].scheduledFor == second.addingTimeInterval(7 * 86_400))
    }

    /// The blocker this pins: an earlier version read the existing pending
    /// cadence reminder first, then decided insert-vs-update from that read.
    /// Two overlapping snoozes for the same contact could both read "nothing
    /// pending" before either had written, and both would insert under a
    /// fresh random id — two pending cadence rows for one contact, and the
    /// two screens reading them could disagree about whether (or until when)
    /// the contact is snoozed. The fix is a deterministic row id derived from
    /// `contactId` alone, so both writes race the *same* primary key and the
    /// later one simply wins — never two rows.
    @Test(
        "Two concurrent snoozes for the same contact resolve to exactly one row, not two",
        arguments: RepositoryContractBackend.allCases
    )
    func concurrentSnoozeResolvesToOneRow(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(503), suffix: "snooze-concurrent", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { now })

        async let first: () = scheduler.snooze(contactId: contact.id)
        async let second: () = scheduler.snooze(contactId: contact.id)
        _ = try await (first, second)

        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].kind == .cadence)
        #expect(pending[0].scheduledFor == now.addingTimeInterval(7 * 86_400))
    }

    @Test("Snooze never logs an interaction or reads lastInteractedAt", arguments: RepositoryContractBackend.allCases)
    func snoozeTouchesOnlyReminders(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(504), suffix: "snooze-no-interaction", tracked: true)
        try await repositories.contacts.upsert(contact)
        let baselineInteractionCount = try await repositories.interactions
            .fetchRecent(forContact: contact.id, limit: 100)
            .count
        // Captured post-upsert, not from the `contact` value itself: both
        // backends normalize `lastInteractedAt` to whole-second precision on
        // write, so comparing against the pre-normalization value would fail
        // on the fractional second alone (R23 mock/production drift).
        let storedBeforeSnooze = try #require(try await repositories.contacts.fetch(id: contact.id)).lastInteractedAt
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await SchedulingPass(reminders: repositories.reminders, clock: { now }).snooze(contactId: contact.id)

        let interactions = try await repositories.interactions.fetchRecent(forContact: contact.id, limit: 100)
        #expect(interactions.count == baselineInteractionCount)
        let storedAfterSnooze = try #require(try await repositories.contacts.fetch(id: contact.id)).lastInteractedAt
        #expect(storedAfterSnooze == storedBeforeSnooze)
    }

    @Test(
        "Snoozing an unknown contact fails the write instead of orphaning a reminder",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeUnknownContactFails(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let unknownContactID = try contractUUID(505)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { now })

        await expectWriteRejected {
            try await scheduler.snooze(contactId: unknownContactID)
        }
    }

    // MARK: - caughtUp (PR #49 hosted review fix)

    @Test(
        "Caught up transitions a pending cadence row to userCaughtUp, dropping it from every pending read",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpTransitionsPendingCadenceRow(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(506), suffix: "caughtup-transition", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { now })
        try await scheduler.snooze(contactId: contact.id)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count == 1)

        try await scheduler.caughtUp(contactId: contact.id)

        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
        #expect(try await repositories.reminders.fetchAllPending()
            .contains { $0.contactId == contact.id } == false)
    }

    @Test(
        "Caught up with no pending reminder is a no-op, not an error",
        arguments: RepositoryContractBackend.allCases
    )
    func caughtUpWithNoPendingRowIsNoOp(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(507), suffix: "caughtup-no-op", tracked: true)
        try await repositories.contacts.upsert(contact)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        // Never snoozed — no pending cadence row exists for this contact.
        try await scheduler.caughtUp(contactId: contact.id)

        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)

        // Calling it again (the "twice in a row" half of idempotence) is
        // equally uneventful.
        try await scheduler.caughtUp(contactId: contact.id)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }
}
