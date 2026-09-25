import Foundation
import Testing
@testable import Regards

/// `SchedulingPass.pendingSnoozeDate` coverage, split out of
/// `SchedulingPassTests` when that struct crossed SwiftLint's 300-line type
/// body limit (staged review round 12) — the same reason
/// `SchedulingPassCaughtUpTests` split out before it. Shares that file's
/// (and `RepositoriesTests.swift`'s) `RepositoryContractBackend` /
/// `contractContact` / `contractUUID` helpers.
struct SchedulingPassPendingSnoozeDateTests {

    /// `pendingSnoozeDate` used to resolve with `.first` over
    /// `fetchPending`'s result, which orders by `scheduledFor` ascending —
    /// picking the *earliest* pending cadence row, not the one that
    /// actually governs. `SchedulingPass.snooze` itself only ever keeps one
    /// cadence row per contact (the deterministic `cadenceReminderID`), but
    /// `SchedulingPassCaughtUpTests.caughtUpNeverTouchesNonCanonicalCadenceRow`
    /// already proves a second, non-canonical cadence row can reach the
    /// table and survive untouched — so this is reachable, not
    /// hypothetical. Fixed to `.map(\.scheduledFor).max()`, matching
    /// `OverdueViewModel.makeOverdueRow`/`UpcomingViewModel.buildRows`'s own
    /// `max($0, $1)` tie-break for the identical shape. This test writes
    /// the *earlier* row first and the later one second, specifically so a
    /// naive "whichever the array lists last" reading would also get this
    /// right by accident — only `.first` (the original bug) or a real
    /// `max()` are actually discriminated against fetch order here.
    @Test(
        "pendingSnoozeDate resolves to the later of two pending cadence rows, not the first fetched",
        arguments: RepositoryContractBackend.allCases
    )
    func pendingSnoozeDateResolvesToLaterRow(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(521), suffix: "pending-snooze-tiebreak", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now }
        )
        let laterDate = now.addingTimeInterval(14 * 86_400)

        try await scheduler.snooze(contactId: contact.id) // the canonical row, now + 7d

        // A second, non-canonical cadence row further out — constructed
        // directly, never produced by `SchedulingPass` itself, mirroring
        // `caughtUpNeverTouchesNonCanonicalCadenceRow`'s own setup. Written
        // *after* the canonical (earlier) row, so `fetchPending`'s
        // ascending-`scheduledFor` order places this one last — the
        // opposite of "whichever came first," to keep the assertion honest
        // about which behavior it's actually proving.
        let laterRow = ScheduledReminder(
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: laterDate,
            osNotificationId: "contact-\(contact.id.uuidString)-stray-later-cadence"
        )
        try await repositories.reminders.upsert(laterRow)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).count == 2)

        let resolved = try await scheduler.pendingSnoozeDate(contactId: contact.id)

        #expect(resolved == laterDate)
    }
}
