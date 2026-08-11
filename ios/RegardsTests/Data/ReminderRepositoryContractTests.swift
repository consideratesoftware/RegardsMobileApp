import Foundation
import Testing
@testable import Regards

/// `ReminderRepository` mock/GRDB contract parity, split out of
/// `RepositoriesTests.swift` when that file crossed SwiftLint's 500-line
/// file limit (staged review round 10). Shares that file's
/// `RepositoryContractBackend` / `contractContact` / `contractUUID` /
/// `contractStored` helpers.
struct ReminderRepositoryContractTests {

    @Test(
        "Pending reads normalize timestamps, round-trip, filter, scope, and sort ties by id",
        arguments: RepositoryContractBackend.allCases
    )
    func pendingOrdering(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(
            id: try contractUUID(301), suffix: "reminder-contact", tracked: true)
        let other = contractContact(
            id: try contractUUID(302), suffix: "reminder-other", tracked: true)
        try await repositories.contacts.upsert(contact)
        try await repositories.contacts.upsert(other)

        let earlier = ScheduledReminder(
            id: try contractUUID(311),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_100.875),
            osNotificationId: "contract-earlier"
        )
        let tiedFirst = ScheduledReminder(
            id: try contractUUID(312),
            contactId: contact.id,
            kind: .birthday,
            occasionDate: "08-07",
            occasionLabel: "Birthday",
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_200.875),
            osNotificationId: "contract-tied-first"
        )
        let tiedSecond = ScheduledReminder(
            id: try contractUUID(313),
            contactId: contact.id,
            kind: .anniversary,
            occasionDate: "08-07",
            occasionLabel: "Anniversary",
            scheduledFor: tiedFirst.scheduledFor,
            osNotificationId: "contract-tied-second"
        )
        let fired = ScheduledReminder(
            id: try contractUUID(314),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_000.875),
            osNotificationId: "contract-fired",
            state: .fired
        )
        let otherPending = ScheduledReminder(
            id: try contractUUID(315),
            contactId: other.id,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_150.875),
            osNotificationId: "contract-other"
        )
        let cancelled = ScheduledReminder(
            id: try contractUUID(316),
            contactId: contact.id,
            kind: .customOccasion,
            occasionDate: "08-08",
            occasionLabel: "Cancelled occasion",
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_050.875),
            osNotificationId: "contract-cancelled",
            state: .cancelled
        )
        let caughtUp = ScheduledReminder(
            id: try contractUUID(317),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_075.875),
            osNotificationId: "contract-caught-up",
            state: .userCaughtUp
        )
        let inserted = [
            tiedSecond, fired, otherPending, earlier, tiedFirst, cancelled, caughtUp,
        ]
        for reminder in inserted {
            try await repositories.reminders.upsert(reminder)
        }

        let contactResult = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(contactResult == [contractStored(earlier), contractStored(tiedFirst), contractStored(tiedSecond)])
        let insertedIDs = Set(inserted.map(\.id))
        let globalResult = try await repositories.reminders.fetchAllPending()
            .filter { insertedIDs.contains($0.id) }
        #expect(globalResult == [
            contractStored(earlier), contractStored(otherPending),
            contractStored(tiedFirst), contractStored(tiedSecond),
        ])
    }

    @Test("Reminder state updates and delete remove pending rows", arguments: RepositoryContractBackend.allCases)
    func updateStateAndDelete(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(
            id: try contractUUID(321), suffix: "reminder-mutation", tracked: true)
        let reminder = ScheduledReminder(
            id: try contractUUID(322),
            contactId: contact.id,
            kind: .birthday,
            occasionDate: "08-07",
            occasionLabel: "Birthday",
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_000.875),
            osNotificationId: "contract-mutation",
            state: .fired
        )
        try await repositories.contacts.upsert(contact)
        try await repositories.reminders.upsert(reminder)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)

        try await repositories.reminders.updateState(id: reminder.id, state: .pending)
        var expected = contractStored(reminder)
        expected.state = .pending
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id) == [expected])

        var replacement = expected
        replacement.kind = .anniversary
        replacement.occasionLabel = "Updated anniversary"
        replacement.scheduledFor = Date(timeIntervalSince1970: 1_800_000_100.875)
        replacement.osNotificationId = "contract-replacement"
        try await repositories.reminders.upsert(replacement)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id) == [contractStored(replacement)])
        try await repositories.reminders.delete(id: reminder.id)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    /// The compare-and-set contract `SchedulingPass.caughtUp`/
    /// `restorePendingAfterFailedCaughtUp` depend on (staged review round
    /// 10): a `transitionState(from:to:)` call whose `from` does not match
    /// the row's *actual* current state must report `false` and leave the
    /// row untouched — on both backends — not silently apply the write or
    /// throw. This is the mismatch case neither backend's earlier coverage
    /// exercised directly (only indirectly, through `SchedulingPass`'s own
    /// race tests).
    @Test(
        "transitionState reports false and writes nothing when from doesn't match the row's actual state",
        arguments: RepositoryContractBackend.allCases
    )
    func transitionStateReportsFalseOnStateMismatch(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(323), suffix: "reminder-transition", tracked: true)
        let reminder = ScheduledReminder(
            id: try contractUUID(324),
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_000.875),
            osNotificationId: "contract-transition",
            state: .pending
        )
        try await repositories.contacts.upsert(contact)
        try await repositories.reminders.upsert(reminder)

        // The row is genuinely `.pending`, not `.fired` — a mismatched
        // `from` must be rejected, not applied anyway.
        let mismatched = try await repositories.reminders.transitionState(
            id: reminder.id, from: .fired, to: .cancelled
        )
        #expect(mismatched == false)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id) == [contractStored(reminder)])

        // The matching `from` still works on the same row — proves the
        // mismatch above was rejected on its own merits, not because
        // `transitionState` is broken outright.
        let matched = try await repositories.reminders.transitionState(
            id: reminder.id, from: .pending, to: .userCaughtUp
        )
        #expect(matched)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }
}
