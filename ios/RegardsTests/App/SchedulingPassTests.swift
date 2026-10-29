import Foundation
import Testing
@testable import Regards

/// `SchedulingPass.snooze` mock/GRDB parity (ARCHITECTURE.md §14 PR22's
/// DB-only stub). Shares `RepositoriesTests.swift`'s `RepositoryContractBackend`
/// / `contractContact` / `contractUUID` helpers.
struct SchedulingPassTests {

    /// The global window, so the 7 calendar days count in UTC on any machine.
    /// `contractContact` carries its own UTC override (every day 10:00-11:00),
    /// which resolves the floor into a slot: 2 hours after an 08:00 floor.
    static let utcWindow = ReminderWindow(
        allowedDays: .allDays,
        allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 17))],
        timezoneIdentifier: "Etc/UTC"
    )

    @Test(
        "Snooze floors a cadence reminder 7 days from the call's clock and resolves it into the window",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeWritesSevenDaysOut(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        try await repositories.window.saveGlobal(Self.utcWindow)
        let contact = contractContact(id: try contractUUID(501), suffix: "snooze-fresh", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { now }
        )

        try await scheduler.snooze(contactId: contact.id)

        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].kind == .cadence)
        #expect(pending[0].state == .pending)
        #expect(pending[0].snoozedUntil == now.addingTimeInterval(7 * 86_400))
        #expect(pending[0].scheduledFor == now.addingTimeInterval(7 * 86_400 + 2 * 3_600))
    }

    /// v3 (§7): a snooze row carries its raw floor, tap time plus 7 calendar
    /// days, and `scheduledFor` is that floor resolved into a window slot. The
    /// floor is what every reader (Overdue, Upcoming, the pass itself) counts
    /// as "snoozed", so the write has to set it.
    @Test(
        "Snooze writes snoozedUntil as the raw floor, before the window resolves scheduledFor",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeWritesRawFloor(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        try await repositories.window.saveGlobal(Self.utcWindow)
        let contact = contractContact(id: try contractUUID(510), suffix: "snooze-floor", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { now }
        )

        try await scheduler.snooze(contactId: contact.id)

        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].snoozedUntil == now.addingTimeInterval(7 * 86_400))
        #expect(pending[0].scheduledFor == now.addingTimeInterval(7 * 86_400 + 2 * 3_600))
    }

    @Test(
        "A second snooze replaces the pending row rather than duplicating it",
        arguments: RepositoryContractBackend.allCases
    )
    func secondSnoozeReplacesNotDuplicates(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        try await repositories.window.saveGlobal(Self.utcWindow)
        let contact = contractContact(id: try contractUUID(502), suffix: "snooze-repeat", tracked: true)
        try await repositories.contacts.upsert(contact)
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let second = first.addingTimeInterval(3 * 86_400)

        try await SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { first }
        )
            .snooze(contactId: contact.id)
        try await SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { second }
        )
            .snooze(contactId: contact.id)

        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].scheduledFor == second.addingTimeInterval(7 * 86_400 + 2 * 3_600))
        #expect(pending[0].snoozedUntil == second.addingTimeInterval(7 * 86_400))
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
        try await repositories.window.saveGlobal(Self.utcWindow)
        let contact = contractContact(id: try contractUUID(503), suffix: "snooze-concurrent", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { now }
        )

        // `Bool`, not `()`: `snooze` returns whether it wrote (R54's
        // precondition), so the async-let bindings type-match that now.
        async let first: Bool = scheduler.snooze(contactId: contact.id)
        async let second: Bool = scheduler.snooze(contactId: contact.id)
        let (firstResult, secondResult) = try await (first, second)

        // Both report success, not just one. Discarding these was how the
        // round-14 compare-and-set shipped a regression through this very
        // test (staged review round 16): the losing call's CAS is rejected
        // because the winner moved the row, and `snooze` briefly reported
        // that as failure — so Contact Detail announced "Couldn't snooze" to
        // VoiceOver for a snooze that had actually happened. The row-count
        // assertion below was true throughout and said nothing about it.
        #expect(firstResult)
        #expect(secondResult)

        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.count == 1)
        #expect(pending[0].kind == .cadence)
        #expect(pending[0].scheduledFor == now.addingTimeInterval(7 * 86_400 + 2 * 3_600))
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

        try await SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { now }
        )
            .snooze(contactId: contact.id)

        let interactions = try await repositories.interactions.fetchRecent(forContact: contact.id, limit: 100)
        #expect(interactions.count == baselineInteractionCount)
        let storedAfterSnooze = try #require(try await repositories.contacts.fetch(id: contact.id)).lastInteractedAt
        #expect(storedAfterSnooze == storedBeforeSnooze)
    }

    /// Behavior shifted at staged review round 11 (R54's fix): an unknown
    /// contact used to reach `reminders.upsert` and fail there, on
    /// whichever backend-specific constraint caught a `ScheduledReminder`
    /// pointing at a nonexistent contact — hence the original title,
    /// "fails the write." Now the precondition's own `contacts.fetch`
    /// simply finds nothing and rejects before ever reaching `upsert`, so
    /// there's no throw to catch — `expectWriteRejected` would record a
    /// false failure here today. The outcome this test actually cares
    /// about (no orphaned reminder for a contact that doesn't exist) is
    /// unchanged, so the title stays true; only how it's proven changes.
    @Test(
        "Snoozing an unknown contact fails the write instead of orphaning a reminder",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeUnknownContactFails(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let unknownContactID = try contractUUID(505)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { now }
        )

        let wrote = try await scheduler.snooze(contactId: unknownContactID)

        #expect(wrote == false)
        let pending = try await repositories.reminders.fetchPending(forContact: unknownContactID)
        #expect(pending.isEmpty)
    }

    /// R54, closed at staged review round 11 — this test used to pin the
    /// gap itself ("snooze writes a pending reminder for an untracked,
    /// no-cadence contact") as a known, deliberately-left-open limitation.
    /// It now proves the fix: `snooze` reads the contact first and rejects
    /// rather than writing. Not reachable through either shipped caller
    /// today (Overdue/Contact Detail's Snooze only ever appear for a row
    /// already computed as overdue, which requires `isCadenceEligible` by
    /// construction) — this test exists for the caller that
    /// isn't either of those yet. `tracked: false` alone covers both
    /// halves of the precondition at once — `contractContact`'s own
    /// fixture ties `cadenceDays` to `tracked`.
    @Test(
        "R54: snooze rejects an untracked, no-cadence contact instead of writing an orphaned reminder",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeRejectsUntrackedNoCadenceContact(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(516), suffix: "snooze-untracked", tracked: false)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { now }
        )

        let wrote = try await scheduler.snooze(contactId: contact.id)

        #expect(wrote == false)
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.isEmpty)
    }

    /// R54's precondition guard was untested for real, staged review found
    /// (round 12): the test above ties `tracked: false` to `cadenceDays:
    /// nil` through `contractContact`'s own fixture, so it can't tell
    /// whether the `tracked` check or the `cadenceDays` check is the one
    /// doing the rejecting — either alone, or neither, would still pass it
    /// if the *other* check happened to still be there. Both view-model
    /// callers also pre-check on a fresh fetch and return before ever
    /// reaching `SchedulingPass.snooze`, so deleting the guard entirely
    /// wouldn't fail anything through them either — the guard had moved
    /// somewhere safer that nothing actually proved was there. This test
    /// and the two below decouple all three conditions the guard checks
    /// (`isActive`, `tracked`, `cadenceDays > 0`, the parts of
    /// `isCadenceEligible`) so each one is provably
    /// load-bearing on its own, calling `scheduler.snooze` directly rather
    /// than through either view model. Verified by deleting the guard
    /// locally and confirming all three fail, not assumed.
    @Test(
        "R54: snooze rejects an untracked contact even with a cadence set",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeRejectsUntrackedContactWithCadence(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        var contact = contractContact(id: try contractUUID(518), suffix: "snooze-untracked-cadence", tracked: false)
        contact.cadenceDays = 14 // decoupled from `tracked` on purpose — see doc comment above
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { now }
        )

        let wrote = try await scheduler.snooze(contactId: contact.id)

        #expect(wrote == false)
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.isEmpty)
    }

    @Test(
        "R54: snooze rejects a tracked contact with no cadence set",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeRejectsTrackedContactWithNoCadence(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        var contact = contractContact(id: try contractUUID(519), suffix: "snooze-tracked-no-cadence", tracked: true)
        contact.cadenceDays = nil // decoupled from `tracked` on purpose — see doc comment above
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { now }
        )

        let wrote = try await scheduler.snooze(contactId: contact.id)

        #expect(wrote == false)
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.isEmpty)
    }

    @Test(
        "A tracked contact with a cadence of 0 days is ineligible for Snooze",
        arguments: RepositoryContractBackend.allCases
    )
    func zeroCadenceIsIneligible(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        var contact = contractContact(id: try contractUUID(534), suffix: "snooze-zero-cadence", tracked: true)
        contact.cadenceDays = 0 // `!= nil` passes; only a positive cadence is a schedule
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { now }
        )

        let wrote = try await scheduler.snooze(contactId: contact.id)

        #expect(wrote == false)
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.isEmpty)
    }

    @Test(
        "R54: snooze rejects an archived contact even when tracked with a cadence set",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeRejectsArchivedTrackedContactWithCadence(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let contact = contractContact(
            id: try contractUUID(520),
            suffix: "snooze-archived",
            tracked: true,
            archivedAt: now.addingTimeInterval(-3_600)
        )
        try await repositories.contacts.upsert(contact)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            window: repositories.window,
            clock: { now }
        )

        let wrote = try await scheduler.snooze(contactId: contact.id)

        #expect(wrote == false)
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending.isEmpty)
    }
}
