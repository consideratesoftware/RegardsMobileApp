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

    // MARK: - Wall-clock snooze (DST)

    /// A DST-observing calendar pinned to a fixed identifier, not
    /// `.current`: these two tests exist specifically to prove the 7-day
    /// push lands on the correct wall-clock day across a DST transition, so
    /// the transition has to be guaranteed present regardless of whichever
    /// timezone the machine running the test happens to be in.
    private static var losAngelesCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }

    /// The bug this pins (staged review, correctness #4): `snooze` used to
    /// compute `clock().addingTimeInterval(7 * 86_400)` — 7 days of *elapsed
    /// seconds*, not 7 *calendar* days. Spring-forward loses an hour of wall
    /// clock inside that window (2027-03-14 in America/Los_Angeles: 2:00 am
    /// becomes 3:00 am), so the elapsed-time math would land the reminder at
    /// 9:00 am local instead of 8:00 am — an hour later than the row's own
    /// "same time next week" label promises, and enough drift for §19's R1
    /// class of bug (already closed for the engine's `nextAllowedSlot` walk)
    /// to reopen here.
    @Test("Snooze across a spring-forward transition lands on the same local wall-clock time")
    func snoozeAcrossSpringForwardStaysOnWallClock() async throws {
        let calendar = Self.losAngelesCalendar
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(508), suffix: "snooze-spring-forward", tracked: true)
        try await repositories.contacts.upsert(contact)
        // 2027-03-08 08:00 local — a week before the 2027-03-14 transition.
        let now = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 3, day: 8, hour: 8, minute: 0
        )))
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { now }, calendar: calendar)

        try await scheduler.snooze(contactId: contact.id)

        let expected = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 3, day: 15, hour: 8, minute: 0
        )))
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending[0].scheduledFor == expected)
        // The bug's own value, named explicitly: proves this is a real
        // discriminator, not incidentally true either way.
        #expect(pending[0].scheduledFor != now.addingTimeInterval(7 * 86_400))
    }

    /// Mirrors `snoozeAcrossSpringForwardStaysOnWallClock` for the other
    /// direction: fall-back *gains* an hour (2027-11-07 in
    /// America/Los_Angeles: 2:00 am becomes 1:00 am), so the old elapsed-time
    /// math would land the reminder at 7:00 am local instead of 8:00 am.
    @Test("Snooze across a fall-back transition lands on the same local wall-clock time")
    func snoozeAcrossFallBackStaysOnWallClock() async throws {
        let calendar = Self.losAngelesCalendar
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(509), suffix: "snooze-fall-back", tracked: true)
        try await repositories.contacts.upsert(contact)
        // 2027-11-01 08:00 local — a week before the 2027-11-07 transition.
        let now = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 11, day: 1, hour: 8, minute: 0
        )))
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { now }, calendar: calendar)

        try await scheduler.snooze(contactId: contact.id)

        let expected = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 11, day: 8, hour: 8, minute: 0
        )))
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending[0].scheduledFor == expected)
        #expect(pending[0].scheduledFor != now.addingTimeInterval(7 * 86_400))
    }

    /// Additional wall-clock coverage (staged review round 8): a snooze from
    /// late December must land in the *following* year, not silently wrap
    /// within the same one — `calendar.date(byAdding: .day, value: 7, to:)`
    /// carries the year rollover for free, but nothing had pinned it, and a
    /// naive component-based reimplementation (e.g. incrementing `.day` in
    /// `DateComponents` without renormalizing month/year) could plausibly
    /// get this wrong in a future rewrite without a test catching it.
    @Test("Snooze across a year boundary rolls over to the next year")
    func snoozeAcrossYearBoundaryRollsOverCorrectly() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Etc/UTC"))
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(514), suffix: "snooze-year-rollover", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 12, day: 28, hour: 8, minute: 0
        )))
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { now }, calendar: calendar)

        try await scheduler.snooze(contactId: contact.id)

        let expected = try #require(calendar.date(from: DateComponents(
            year: 2028, month: 1, day: 4, hour: 8, minute: 0
        )))
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending[0].scheduledFor == expected)
    }

    /// Additional wall-clock coverage (staged review round 8): every DST
    /// fixture above uses an hour-aligned zone (`America/Los_Angeles`).
    /// `Asia/Kolkata` is a fixed, non-DST-observing UTC+5:30 offset — this
    /// isolates whether the half-hour offset itself (not a transition) has
    /// any effect on the wall-clock math, which it should not: the 7-day
    /// push lands at the identical local time regardless of how the zone's
    /// UTC offset happens to be shaped.
    @Test("Snooze in a half-hour-offset timezone lands on the same local wall-clock time")
    func snoozeInHalfHourOffsetTimezoneStaysOnWallClock() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(515), suffix: "snooze-half-hour-offset", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 6, day: 1, hour: 8, minute: 15
        )))
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { now }, calendar: calendar)

        try await scheduler.snooze(contactId: contact.id)

        let expected = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 6, day: 8, hour: 8, minute: 15
        )))
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending[0].scheduledFor == expected)
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

        // The return value (round 7): `true` — a pending row genuinely
        // existed and was transitioned, not just "the write ran."
        let clearedSomething = try await scheduler.caughtUp(contactId: contact.id)

        #expect(clearedSomething)
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
        // The `false` return (round 7) is the signal a caller uses to skip
        // any later restore-on-failure compensation.
        let clearedSomething = try await scheduler.caughtUp(contactId: contact.id)
        #expect(clearedSomething == false)

        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)

        // Calling it again (the "twice in a row" half of idempotence) is
        // equally uneventful, and still reports nothing was pending to clear.
        let secondCall = try await scheduler.caughtUp(contactId: contact.id)
        #expect(secondCall == false)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    /// The blocker this pins (staged review round 8, "the worst of the
    /// four" — the coordinator's own words): round 7's `caughtUp` paired a
    /// separate `fetchPending` read with `updateState`, leaving a window
    /// where two concurrent callers for the same contact could both observe
    /// the row as pending and both report `true`. If one caller's later
    /// write then failed, its restore would re-pend a snooze the *other*,
    /// successful caller had legitimately cleared. `async let` drives two
    /// genuinely concurrent `caughtUp` calls the same way
    /// `concurrentSnoozeResolvesToOneRow` above drives two concurrent
    /// `snooze` calls — Swift actor re-entrancy at `caughtUp`'s own `await`
    /// lets both bodies interleave before either's `transitionState` write
    /// lands, so this reproduces the race rather than assuming it.
    @Test(
        "Two concurrent caught-ups on the same pending row: only one reports having cleared it",
        arguments: RepositoryContractBackend.allCases
    )
    func concurrentCaughtUpOnlyOneWinsTheTransition(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(512), suffix: "caughtup-concurrent", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { now })
        try await scheduler.snooze(contactId: contact.id)

        async let first = scheduler.caughtUp(contactId: contact.id)
        async let second = scheduler.caughtUp(contactId: contact.id)
        let (firstCleared, secondCleared) = try await (first, second)

        // Exactly one call transitioned a genuinely pending row; the other
        // found it already `.userCaughtUp` and correctly reported nothing to
        // restore — the discriminator round 7's separate-read design could
        // not make (it could report `true` for both).
        #expect([firstCleared, secondCleared].filter { $0 }.count == 1)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    // MARK: - restorePendingAfterFailedCaughtUp (staged review round 7)

    /// The compensation this pins: a caller's own later write fails after
    /// `caughtUp` already cleared a real snooze, and the exact same row
    /// (same id, same `scheduledFor`) comes back — not a freshly computed
    /// `now + 7d` from a second `snooze()` call.
    @Test(
        "Restoring after a failed caught-up brings back the exact same pending row",
        arguments: RepositoryContractBackend.allCases
    )
    func restorePendingAfterFailedCaughtUpBringsBackSameRow(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(510), suffix: "caughtup-restore", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { now })
        try await scheduler.snooze(contactId: contact.id)
        let original = try await repositories.reminders.fetchPending(forContact: contact.id)[0]
        _ = try await scheduler.caughtUp(contactId: contact.id)
        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)

        try await scheduler.restorePendingAfterFailedCaughtUp(contactId: contact.id)

        let restored = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(restored.count == 1)
        #expect(restored[0].id == original.id)
        #expect(restored[0].scheduledFor == original.scheduledFor)
        #expect(restored[0].state == .pending)
    }

    /// Calling this without a preceding `caughtUp` in the same action is
    /// meant to be safe (no row exists at the deterministic id yet), matching
    /// `caughtUp`'s own no-op-when-nothing-matches idempotence.
    @Test(
        "Restoring with nothing to restore is a no-op, not an error",
        arguments: RepositoryContractBackend.allCases
    )
    func restorePendingAfterFailedCaughtUpWithNothingPendingIsNoOp(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(511), suffix: "caughtup-restore-noop", tracked: true)
        try await repositories.contacts.upsert(contact)
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        try await scheduler.restorePendingAfterFailedCaughtUp(contactId: contact.id)

        #expect(try await repositories.reminders.fetchPending(forContact: contact.id).isEmpty)
    }

    /// The compare-and-set this pins (round 8): a re-snooze between
    /// `caughtUp` and its would-be restore leaves the row `.pending` again
    /// with a *new* `scheduledFor` — restoring must not fire at all here
    /// (the row is no longer `.userCaughtUp`, the state this call is only
    /// ever allowed to move away from), or it would silently discard the
    /// fresh snooze the user just set.
    @Test(
        "Restoring after a re-snooze leaves the fresh snooze alone",
        arguments: RepositoryContractBackend.allCases
    )
    func restorePendingAfterFailedCaughtUpDoesNotClobberAFreshSnooze(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(513), suffix: "caughtup-restore-resnoozed", tracked: true)
        try await repositories.contacts.upsert(contact)
        let firstNow = Date(timeIntervalSince1970: 1_800_000_000)
        let secondNow = firstNow.addingTimeInterval(3 * 86_400)
        let scheduler = SchedulingPass(reminders: repositories.reminders, clock: { firstNow })
        try await scheduler.snooze(contactId: contact.id)
        _ = try await scheduler.caughtUp(contactId: contact.id)
        // Re-snoozed from a later clock reading before the compensation for
        // the *earlier* caught-up ever runs — simulates the user snoozing
        // again while an earlier failed action's restore is still pending.
        try await SchedulingPass(reminders: repositories.reminders, clock: { secondNow })
            .snooze(contactId: contact.id)
        let freshSnooze = try await repositories.reminders.fetchPending(forContact: contact.id)[0]

        try await scheduler.restorePendingAfterFailedCaughtUp(contactId: contact.id)

        let afterRestore = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(afterRestore.count == 1)
        #expect(afterRestore[0].scheduledFor == freshSnooze.scheduledFor)
        #expect(afterRestore[0].scheduledFor == secondNow.addingTimeInterval(7 * 86_400))
    }
}
