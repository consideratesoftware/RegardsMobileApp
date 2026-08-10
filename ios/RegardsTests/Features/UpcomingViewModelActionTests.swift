import Foundation
import Testing
@testable import Regards

/// "Mark caught up" persistence and cross-screen live updates for
/// `UpcomingViewModel` (ARCHITECTURE.md §14 PR22). The boundary/duplicate/
/// state suites own load-path derivation; this file owns the async action
/// and `observeTracked()` behavior.
@MainActor
struct UpcomingViewModelActionTests {

    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func contact(
        id: UUID = UUID(),
        cadenceDays: Int = 7,
        lastInteractedAt: Date
    ) -> Contact {
        Contact(
            id: id,
            systemContactRef: "sys-\(id.uuidString)",
            displayName: "Leia Organa",
            tracked: true,
            cadenceDays: cadenceDays,
            priorityTier: .close,
            preferredChannel: .whatsapp,
            preferredChannelValue: "+14155550140",
            lastInteractedAt: lastInteractedAt
        )
    }

    @Test("Caught up removes every row for the contact instantly and persists the interaction")
    func markCaughtUpRemovesRowsAndPersists() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            interactions: interactions,
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.totalCount == 1)

        await viewModel.markCaughtUp(contactId: contact.id)

        #expect(viewModel.totalCount == 0)
        #expect(viewModel.groups.isEmpty)
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == Self.now)
    }

    @Test("A failing caught-up write reloads to restore the true state")
    func markCaughtUpFailureReloads() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            interactions: StubInteractionRepository.failing(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.totalCount == 1)

        await viewModel.markCaughtUp(contactId: contact.id)

        #expect(viewModel.totalCount == 1)
    }

    @Test("A write on the same repository through a different reference is reflected live")
    func liveUpdateReflectsWriteFromAnotherReference() async throws {
        // A horizon *shorter* than the cadence, deliberately: with the
        // default 14-day horizon, pushing `lastInteractedAt` to `now` still
        // leaves the next cadence due date (now + 7d, cadenceDays: 7) inside
        // the horizon, so the row would correctly persist with a new date —
        // not disappear. A 5-day horizon makes "now + 7d" fall outside it, so
        // the write's effect is genuinely "the row leaves Upcoming," matching
        // what this test asserts.
        let window = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 0), end: TimeOfDay(hour: 23, minute: 59))],
            timezoneIdentifier: UpcomingFixtures.utc.identifier,
            digestHorizonDays: 5
        )
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            interactions: StubInteractionRepository(),
            window: window,
            clock: { Self.now }
        )
        await viewModel.load()
        // Pre-write: 10 days since last contact, cadence 7 → 3 days overdue,
        // due date is effectively `now` → inside the 5-day horizon.
        #expect(viewModel.totalCount == 1)

        // Simulates Contact Detail marking the contact caught up through its
        // own reference to the same repository. Post-write due date is
        // `now + 7d`, outside the 5-day horizon.
        var updated = contact
        updated.lastInteractedAt = Self.now
        try await contacts.upsert(updated)

        // The write reaches Upcoming through `observeTracked()`'s subscriber
        // Task, not a call this test itself awaits — `waitUntil` yields
        // cooperatively until it drains rather than sleeping a fixed delay.
        let sawZero = await waitUntil { viewModel.totalCount == 0 }
        #expect(sawZero)
    }

    // MARK: - Snooze (§14 PR22 SchedulingPass stub)
    //
    // Upcoming has no Snooze control of its own (§10: its swipe actions are
    // "Reach out now" / "Mark caught up") — these tests cover the *read*
    // side: a snooze written from Overdue or Contact Detail through the same
    // `ReminderRepository` must still change what this screen shows. There
    // is no `observeTracked()`-style push for reminder writes, so a snooze's
    // effect only appears on the next `load()`, not instantly.

    /// `UpcomingFixtures.now` is exactly 08:00:00 UTC (2027-01-15). Anchoring
    /// the allowed range's start to that same hour keeps `nextAllowedSlot`'s
    /// slot-start snapping from shifting the asserted dates by up to a day —
    /// with an allowed range starting at midnight instead, a target that
    /// lands mid-day snaps *forward to the next day's slot start* under
    /// `includingContainingSlot: false` (the future-cadence branch), not to
    /// the target's own day. Anchoring lets these tests assert exact date
    /// equality instead of a same-day check.
    static func eightAMWindow(digestHorizonDays: Int = ReminderWindow.defaultDigestHorizonDays) -> ReminderWindow {
        ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 23, minute: 59))],
            timezoneIdentifier: UpcomingFixtures.utc.identifier,
            digestHorizonDays: digestHorizonDays
        )
    }

    @Test("A snoozed contact's row reflects the persisted snooze date, not the live-computed one")
    func snoozedRowUsesPersistedDate() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, clock: { Self.now })
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            interactions: StubInteractionRepository(),
            window: Self.eightAMWindow(),
            clock: { Self.now }
        )
        await viewModel.load()
        let beforeRow = try #require(viewModel.groups.flatMap(\.rows).first)
        // 3 days overdue (10 days since contact, cadence 7): the immediate
        // slot is `now` itself.
        #expect(beforeRow.scheduledFor == Self.now)

        try await scheduler.snooze(contactId: contact.id)
        await viewModel.load()

        let afterRow = try #require(viewModel.groups.flatMap(\.rows).first)
        #expect(afterRow.scheduledFor == Self.now.addingTimeInterval(7 * 86_400))
    }

    @Test("A snoozed row leaves Upcoming when the horizon is shorter than the snooze, and returns once it lapses")
    func snoozedRowLeavesAndReturnsWithTighterHorizon() async throws {
        // Horizon shorter than the cadence, deliberately: with the default
        // 14-day horizon, a "now + 7d" snoozed row would stay visible the
        // whole time, which wouldn't exercise "leaves and returns" at all.
        let window = Self.eightAMWindow(digestHorizonDays: 5)
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let clock = MutableClock(Self.now)
        let scheduler = SchedulingPass(reminders: reminders, clock: clock.now)
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            interactions: StubInteractionRepository(),
            window: window,
            clock: clock.now
        )
        await viewModel.load()
        #expect(viewModel.totalCount == 1)

        try await scheduler.snooze(contactId: contact.id) // now + 7d, outside the 5-day horizon
        await viewModel.load()
        #expect(viewModel.totalCount == 0)

        clock.advance(by: 8 * 86_400) // past the snoozed date
        await viewModel.load()
        // Returns via the ordinary lastInteractedAt-based path — the lapsed
        // snooze is no longer consulted, and the contact is now far overdue.
        #expect(viewModel.totalCount == 1)
    }

    /// Advancing "a few days" (the sibling test above uses 8) never actually
    /// lands on the boundary itself. `max(overdueAt, snoozedUntil) <= now`
    /// is `<=`, not `<` — at the exact instant the snooze target arrives,
    /// the reminder must already read as due (back in view), not merely
    /// "due sometime after."
    @Test("A snoozed row returns to Upcoming at exactly the 7-day mark, not just after it")
    func snoozedRowReturnsAtExactSevenDayBoundary() async throws {
        let window = Self.eightAMWindow(digestHorizonDays: 5)
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let clock = MutableClock(Self.now)
        let scheduler = SchedulingPass(reminders: reminders, clock: clock.now)
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            interactions: StubInteractionRepository(),
            window: window,
            clock: clock.now
        )
        await viewModel.load()

        try await scheduler.snooze(contactId: contact.id) // scheduledFor == now + 7d
        await viewModel.load()
        #expect(viewModel.totalCount == 0) // now + 7d is outside the 5-day horizon

        clock.advance(by: 7 * 86_400) // now' == now + 7d, exactly the snooze target
        await viewModel.load()

        // At now' == snoozedUntil exactly: `max(overdueAt, snoozedUntil) <=
        // now'` is true (equality), so this resolves through the
        // "already-due" branch — the same branch a genuinely overdue
        // contact resolves through — landing at the active slot starting
        // `now'` itself, which is inside the (now') + 5d horizon.
        #expect(viewModel.totalCount == 1)
        #expect(viewModel.groups.flatMap(\.rows).first?.scheduledFor == clock.now())
    }

    /// Pins §14 PR22's "later caught-up beats a stale snooze" fix: with the
    /// snooze routed through the same `target`/`includingContainingSlot`
    /// computation as the ordinary cadence math (not read verbatim), a
    /// caught-up that lands *after* an existing snooze naturally produces a
    /// later date than the stale snooze, because `overdueAt` (freshly
    /// anchored on the new `lastInteractedAt`) becomes the larger of the two
    /// `max(...)` candidates.
    @Test("A caught-up after a snooze computes the row from the fresh lastInteractedAt, not the stale snooze")
    func caughtUpAfterSnoozeBeatsStaleSnooze() async throws {
        let window = Self.eightAMWindow()
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, clock: { Self.now })
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            interactions: StubInteractionRepository(),
            window: window,
            clock: { Self.now }
        )
        await viewModel.load()

        try await scheduler.snooze(contactId: contact.id) // pending cadence @ now + 7d
        await viewModel.load()
        #expect(viewModel.groups.flatMap(\.rows).first?.scheduledFor == Self.now.addingTimeInterval(7 * 86_400))

        // A caught-up (from Contact Detail, say) moves lastInteractedAt to
        // `now`. Widening the cadence to 10 days makes the fresh due date
        // (now + 10d) later than the stale snooze (now + 7d) — unambiguously
        // distinct — while staying inside the default 14-day horizon.
        var caughtUp = contact
        caughtUp.cadenceDays = 10
        caughtUp.lastInteractedAt = Self.now
        try await contacts.upsert(caughtUp)
        await viewModel.load()

        // Fresh overdueAt = now + 10d, later than the stale snooze (now +
        // 7d) — `max(...)` picks the fresh value, proving caught-up wins.
        // `waitUntil` rather than a bare `#expect` on the state right after
        // `load()`: the `upsert` above also broadcasts to this view model's
        // own `observeTracked()` subscription (opened back at the first
        // `load()`), so a redundant background reload can still be
        // in flight — harmless once it resolves to the same correct state,
        // but a assertion timed to land in the middle of it would be racing
        // internals this test isn't about.
        let expected = Self.now.addingTimeInterval(10 * 86_400)
        let sawFreshDate = await waitUntil {
            viewModel.groups.flatMap(\.rows).first?.scheduledFor == expected
        }
        #expect(sawFreshDate)
    }

    @Test("Two concurrent load() calls subscribe to observeTracked() exactly once")
    func concurrentLoadSubscribesOnce() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            interactions: StubInteractionRepository(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { Self.now }
        )

        async let firstLoad: () = viewModel.load()
        async let secondLoad: () = viewModel.load()
        _ = await (firstLoad, secondLoad)

        #expect(await contacts.subscriptionCount() == 1)
    }
}
