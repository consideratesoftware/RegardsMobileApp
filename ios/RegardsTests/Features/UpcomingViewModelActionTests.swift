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
        // A 5-day horizon, deliberately shorter than the 7-day default
        // cadence: `markCaughtUp` reloads on success (see its doc comment),
        // and that reload legitimately computes a *new* upcoming cadence
        // reminder at now + 7d for this contact — a real future reminder,
        // not stale state. A horizon that excludes it is what makes "caught
        // up empties this list" true here; the default 14-day horizon would
        // not empty it, correctly.
        let window = ReminderWindow.allDayEveryDay(timezone: UpcomingFixtures.utc, digestHorizonDays: 5)
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            interactions: interactions,
            window: window,
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

    /// Discriminates the occasion-preservation fix from the pre-fix filter
    /// it replaced. Every other test in this file passes `reminders: nil`,
    /// so `buildRows` never produces an occasion row and the two filter
    /// shapes — `!($0.contactId == contactId && $0.kind == .cadence)` (the
    /// fix) vs. the older `$0.contactId != contactId` — agree on every one
    /// of them; this is the only test that puts a real pending occasion
    /// reminder in front of `markCaughtUp` so the two filters actually
    /// diverge. Reverting to the old filter turns this red: it would drop
    /// the birthday row too, since it doesn't look at `kind` at all.
    @Test("Caught up removes only the contact's cadence row, leaving a same-contact occasion row in place")
    func markCaughtUpPreservesOccasionRowRemovesOnlyCadence() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let birthday = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            scheduledFor: Self.now.addingTimeInterval(3_600),
            osNotificationId: "contact-\(contact.id.uuidString)-birthday"
        )
        try await reminders.upsert(birthday)
        let interactions = StubInteractionRepository()
        // A 5-day horizon — see `markCaughtUpRemovesRowsAndPersists`'
        // sibling comment: `markCaughtUp`'s reload legitimately computes a
        // new upcoming cadence reminder at now + 7d, which must fall outside
        // the horizon for "only the birthday row remains" to hold.
        let window = ReminderWindow.allDayEveryDay(timezone: UpcomingFixtures.utc, digestHorizonDays: 5)
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
            interactions: interactions,
            window: window,
            clock: { Self.now }
        )
        await viewModel.load()
        // Two rows pre-action for this one contact: the cadence row (3 days
        // overdue, due now) and the birthday occasion row an hour out.
        #expect(viewModel.totalCount == 2)

        await viewModel.markCaughtUp(contactId: contact.id)

        let remaining = viewModel.groups.flatMap(\.rows)
        #expect(remaining.count == 1)
        #expect(remaining.first?.kind == .birthday)
        #expect(viewModel.totalCount == 1)
    }

    @Test("A failing caught-up write reloads to restore the true state")
    func markCaughtUpFailureReloads() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            interactions: StubInteractionRepository.failing(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.totalCount == 1)

        await viewModel.markCaughtUp(contactId: contact.id)

        #expect(viewModel.totalCount == 1)
    }

    /// The three-write partial-failure shape `markCaughtUpFailureReloads`
    /// above doesn't reach: that test fails `interactions.append` itself
    /// (via `StubInteractionRepository.failing()`), so nothing persists at
    /// all. Correctness fix (staged review #7) reordered `markCaughtUp` to
    /// run `scheduler.caughtUp` *before* `InteractionLogging` — see its doc
    /// Rerouted off a hand-rolled `contacts.upsert(...)` (staged review round
    /// 6) — see `OverdueViewModelActionTests`'s sibling test for why: it
    /// used to prove `observeTracked()` fires on a write method production no
    /// longer calls for this action.
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
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            interactions: StubInteractionRepository(),
            window: window,
            clock: { Self.now }
        )
        await viewModel.load()
        // Pre-write: 10 days since last contact, cadence 7 → 3 days overdue,
        // due date is effectively `now` → inside the 5-day horizon.
        #expect(viewModel.totalCount == 1)

        // Simulates Contact Detail's own `ContactDetailViewModel.markCaughtUp`
        // — its `InteractionLogging` call — marking the contact caught up
        // through the same repository reference. Post-write due date is
        // `now + 7d`, outside the 5-day horizon.
        let logging = InteractionLogging(contacts: contacts, interactions: StubInteractionRepository())
        try await logging.markCaughtUp(contactId: contact.id, at: Self.now)

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
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
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
            scheduler: SchedulingPass(reminders: reminders, clock: clock.now),
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
            scheduler: SchedulingPass(reminders: reminders, clock: clock.now),
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
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
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

    /// The actual bug this closes (PR #49 hosted review), which
    /// `caughtUpAfterSnoozeBeatsStaleSnooze` above cannot catch:
    /// that test widens the cadence to 10 days and writes `lastInteractedAt`
    /// directly via `contacts.upsert`, never calling `markCaughtUp` itself —
    /// so it can't see whether the real action clears the pending snooze row
    /// or not. With cadence *unchanged* at 3 days, the fresh due date
    /// (now + 3d) is *earlier* than the stale snooze (now + 7d), so
    /// `max(now, overdueAt, snoozedUntil)` keeps picking the stale
    /// snoozedUntil unless `markCaughtUp` actually clears the pending row —
    /// this is the shape that shipped broken.
    @Test("Caught up after a snooze with a short cadence shows the fresh date, not the stale snooze")
    func caughtUpAfterSnoozeShowsFreshDateWithShortCadence() async throws {
        let window = Self.eightAMWindow()
        let contact = Self.contact(cadenceDays: 3, lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let scheduler = SchedulingPass(reminders: reminders, clock: { Self.now })
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            scheduler: scheduler,
            interactions: StubInteractionRepository(),
            window: window,
            clock: { Self.now }
        )
        await viewModel.load()

        try await scheduler.snooze(contactId: contact.id) // pending cadence @ now + 7d
        await viewModel.load()
        #expect(viewModel.groups.flatMap(\.rows).first?.scheduledFor == Self.now.addingTimeInterval(7 * 86_400))

        await viewModel.markCaughtUp(contactId: contact.id)

        // `waitUntil`, not a bare `#expect`: `markCaughtUp` reloads
        // explicitly on success (see its doc comment), but a redundant
        // reactive reload from the contact-upsert broadcast can still land
        // around the same time — harmless once both resolve to the same
        // correct state.
        let expected = Self.now.addingTimeInterval(3 * 86_400)
        let sawFreshDate = await waitUntil {
            viewModel.groups.flatMap(\.rows).first?.scheduledFor == expected
        }
        #expect(sawFreshDate)
        #expect(viewModel.groups.flatMap(\.rows).first?.scheduledFor != Self.now.addingTimeInterval(7 * 86_400))
    }

    @Test("Two concurrent load() calls subscribe to observeTracked() exactly once")
    func concurrentLoadSubscribesOnce() async throws {
        let contact = Self.contact(lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
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
