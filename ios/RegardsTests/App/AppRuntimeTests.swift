import Foundation
import Testing
@testable import Regards

struct AppRuntimeTests {

    @Test("App mock composition renders occasions in its own forward horizon")
    @MainActor
    func mockCompositionSharesClockAndWindow() async throws {
        let runtime = AppRuntime.makeMock()
        let viewModel = RegardsTabRoot.makeUpcomingViewModel(runtime: runtime)
        // The seed cast's birthday and anniversary come from the occasion
        // provider; the pass writes their rows.
        try await runtime.scheduler.runFull()

        await viewModel.load()

        let occasionRows = viewModel.groups
            .flatMap(\.rows)
            .filter { $0.kind != .cadence }
        let calendar = UpcomingViewModel.gregorianCalendar(
            for: runtime.window.timeZone
        )
        let now = runtime.clock()
        let horizonEnd = try #require(
            calendar.date(byAdding: .day, value: viewModel.horizonDays, to: now)
        )
        #expect(Set(occasionRows.map(\.kind)) == [.birthday, .anniversary])
        #expect(occasionRows.allSatisfy {
            $0.scheduledFor >= now && $0.scheduledFor < horizonEnd
        })
        #expect(try await runtime.environment.window.fetchGlobal() == runtime.window)
    }

    @Test("Every time-derived screen shares the root runtime clock")
    @MainActor
    func rootCompositionSharesClockAcrossScreens() async throws {
        let runtime = AppRuntime.makeMock()
        let group = try #require(try await runtime.environment.groups.fetchAll().first)
        let contact = try #require(
            try await runtime.environment.contacts.fetch(id: group.primaryContactId)
        )
        let overdue = RegardsTabRoot.makeOverdueViewModel(runtime: runtime)
        let allContacts = RegardsTabRoot.makeAllContactsViewModel(runtime: runtime)
        let detail = RegardsTabRoot.makeContactDetailViewModel(
            contactId: contact.id,
            runtime: runtime
        )

        await overdue.load()
        await allContacts.load()
        await detail.load()

        let overdueRow = try #require(overdue.rows.first { $0.contactId == contact.id })
        let relative = try #require(
            Contact.relativeDescription(for: contact.lastInteractedAt, from: allContacts.now)
        )
        #expect(allContacts.now == runtime.clock())
        // No `overdueRow.lastInteractedText` assertion here any more (staged
        // review round 11): the field it read was removed from
        // `OverdueRowState` once nothing rendered it — see that struct's own
        // doc comment. Coverage isn't lost: `allContacts.now == runtime.clock()`
        // above and `detail.overdueSummary.days == overdueRow.overdueDays`
        // below already chain allContacts → runtime and detail → overdue
        // through values each screen still exposes, which is transitively
        // the same "every screen shares one clock" guarantee this test is
        // named for.
        #expect(detail.lastTalkedLabel.hasPrefix(relative))
        #expect(detail.overdueSummary.days == overdueRow.overdueDays)
    }

    @Test("Production runtime uses live device timing instead of mock timing")
    func productionRuntimeDoesNotRetainMockTiming() async throws {
        let seedEnvironment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let persistedWindow = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [
                TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 10)),
            ],
            timezoneIdentifier: "America/Los_Angeles"
        )
        try await seedEnvironment.window.saveGlobal(persistedWindow)

        let runtime = try await AppRuntime.makeProduction(environment: seedEnvironment)

        #expect(runtime.window == persistedWindow)
        #expect(runtime.userCalendar.timeZone.identifier == TimeZone.current.identifier)
        #expect(runtime.clock() != MockRepositories.defaultNow)
        #expect(try await runtime.environment.window.fetchGlobal() == runtime.window)
    }

    /// The bug this pins (staged review round 6): `AppRuntime.init` used to
    /// wire `userCalendar` — the *device's* timezone, snapshotted once at
    /// launch — into `scheduler` instead of `window.timeZone`, the persisted
    /// reminder window's own timezone. `userCalendar` here is pinned to
    /// `Etc/GMT+8`, a fixed UTC-8 offset that never observes DST — sharing
    /// `America/Los_Angeles`'s pre-transition offset exactly, so the two
    /// zones agree at `now` and only diverge once LA's own spring-forward
    /// lands. If `scheduler` still resolved through `userCalendar`, the
    /// 7-day snooze push would land an hour off `window.timeZone`'s own
    /// "same local wall-clock time" answer; mirrors
    /// `SchedulingPassTests.snoozeAcrossSpringForwardStaysOnWallClock`, one
    /// level up the composition (`AppRuntime`, not `SchedulingPass` directly).
    @Test("Runtime scheduler resolves the persisted window's timezone, not the device calendar's, across DST")
    func schedulerResolvesWindowTimezoneAcrossDSTBoundary() async throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        var laCalendar = Calendar(identifier: .gregorian)
        laCalendar.timeZone = losAngeles
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = try #require(TimeZone(identifier: "Etc/GMT+8"))

        // 2027-03-08 08:00 local — a week before LA's 2027-03-14
        // spring-forward. Both zones agree here: confirms any divergence in
        // the result below is attributable to the transition itself, not a
        // baseline offset difference between the two calendars.
        let now = try #require(laCalendar.date(from: DateComponents(
            year: 2027, month: 3, day: 8, hour: 8, minute: 0
        )))
        #expect(deviceCalendar.date(from: DateComponents(
            year: 2027, month: 3, day: 8, hour: 8, minute: 0
        )) == now)

        let seedEnvironment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let contact = contractContact(id: try contractUUID(510), suffix: "runtime-tz-dst", tracked: true)
        try await seedEnvironment.contacts.upsert(contact)
        let window = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 10))],
            timezoneIdentifier: losAngeles.identifier
        )

        // The pass reads the persisted window on each call (R55), so this is
        // the zone that must win over `userCalendar`.
        try await seedEnvironment.window.saveGlobal(window)
        let runtime = AppRuntime(
            environment: seedEnvironment,
            window: window,
            userCalendar: deviceCalendar,
            clock: { now },
            occasions: { _ in [] }
        )
        try await runtime.scheduler.snooze(contactId: contact.id)

        let expectedFromWindowTimezone = try #require(laCalendar.date(from: DateComponents(
            year: 2027, month: 3, day: 15, hour: 8, minute: 0
        )))
        let wrongIfUsingDeviceCalendar = try #require(deviceCalendar.date(from: DateComponents(
            year: 2027, month: 3, day: 15, hour: 8, minute: 0
        )))
        let pending = try await seedEnvironment.reminders.fetchPending(forContact: contact.id)
        #expect(pending[0].snoozedUntil == expectedFromWindowTimezone)
        // The bug's own value, named explicitly: proves this is a real
        // discriminator, not incidentally true either way.
        #expect(pending[0].snoozedUntil != wrongIfUsingDeviceCalendar)
    }

    @Test("Production composition uses the persisted digest horizon", arguments: [7, 30])
    @MainActor
    func productionCompositionUsesPersistedDigestHorizon(horizonDays: Int) async throws {
        let seedEnvironment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let persistedWindow = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [
                TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 10)),
            ],
            timezoneIdentifier: "America/Los_Angeles",
            digestHorizonDays: horizonDays
        )
        try await seedEnvironment.window.saveGlobal(persistedWindow)

        let runtime = try await AppRuntime.makeProduction(environment: seedEnvironment)
        let viewModel = RegardsTabRoot.makeUpcomingViewModel(runtime: runtime)

        #expect(runtime.window.digestHorizonDays == horizonDays)
        #expect(viewModel.horizonDays == horizonDays)
    }

    /// Composition seam: the Settings editor's save reaches the Upcoming view
    /// model the tabs show (I2), and changes nothing besides the edited field.
    @Test("Saving the Settings editor updates the Upcoming horizon and keeps every other field")
    @MainActor
    func settingsEditorSaveUpdatesUpcoming() async throws {
        let runtime = AppRuntime.makeMock()
        let upcoming = RegardsTabRoot.makeUpcomingViewModel(runtime: runtime)
        let editor = RegardsTabRoot.makeReminderWindowsViewModel(runtime: runtime, upcoming: upcoming)
        await editor.load()
        let before = try await runtime.environment.window.fetchGlobal()
        let newHorizon = before.digestHorizonDays == 7 ? 30 : 7
        editor.draft.digestHorizonDays = newHorizon

        let saved = await editor.save()

        #expect(saved)
        #expect(upcoming.horizonDays == newHorizon)
        let after = try await runtime.environment.window.fetchGlobal()
        #expect(after.digestHorizonDays == newHorizon)
        #expect(upcoming.window == after)
        #expect(after.allowedDays == before.allowedDays)
        #expect(after.allowedTimeRanges == before.allowedTimeRanges)
        #expect(after.quietHours == before.quietHours)
        #expect(after.timezoneIdentifier == before.timezoneIdentifier)
        #expect(after.occasionTime == before.occasionTime)
    }

    /// Composition seam (§9: starter tracking is a cadence edit): the Settings
    /// starter picker's save reaches the runtime's one pass through
    /// `run(for:)` for the contacts it changed, so an untracked contact's
    /// pending row is cancelled and a newly tracked one is scheduled before the
    /// screen closes. An unrelated tracked contact (Zoe) holds a stale row that
    /// only a full run would rewrite: the save must leave it alone. The runtime
    /// has a fixed clock and a UTC calendar, so the contacts are 100 days
    /// overdue at a known `now`.
    @Test("The Settings starter picker reschedules only the contacts it changed, through the pass")
    @MainActor
    func settingsStarterPickerSchedulesAndCancelsThroughThePass() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let runtime = try await Self.fixedClockRuntime(environment)
        let longAgo = runtime.clock().addingTimeInterval(-100 * 86_400)
        let xena = Contact(
            systemContactRef: "starter-xena", displayName: "Xena",
            tracked: true, cadenceDays: 7, lastInteractedAt: longAgo)
        let yara = Contact(systemContactRef: "starter-yara", displayName: "Yara", lastInteractedAt: longAgo)
        let zoe = Contact(
            systemContactRef: "starter-zoe", displayName: "Zoe",
            tracked: true, cadenceDays: 7, lastInteractedAt: longAgo)
        for contact in [xena, yara, zoe] { try await environment.contacts.upsert(contact) }
        try await runtime.scheduler.runFull()
        func cadenceRow(_ contact: Contact) async throws -> ScheduledReminder? {
            try await environment.reminders.fetchPending(forContact: contact.id).first { $0.kind == .cadence }
        }
        #expect(try await cadenceRow(xena) != nil, "Setup: the tracked contact is scheduled.")
        #expect(try await cadenceRow(yara) == nil)
        // Make Zoe's stored row disagree with what the pass would compute. A
        // due row is kept as is, so the stale row sits in the future, where a
        // full run moves it back to her overdue slot.
        var stale = try #require(try await cadenceRow(zoe))
        stale.scheduledFor = runtime.clock().addingTimeInterval(30 * 86_400)
        try await environment.reminders.upsert(stale)
        let picker = RegardsTabRoot.makeStarterContactsViewModel(runtime: runtime)
        await picker.load()
        picker.toggle(xena.id)
        picker.toggle(yara.id)

        #expect(await picker.save())

        #expect(try await cadenceRow(xena) == nil, "Untracking cancels the pending row.")
        #expect(try await cadenceRow(yara) != nil, "Tracking schedules a row.")
        #expect(try await cadenceRow(zoe) == stale, "A contact the save did not change is not rescheduled.")
        // Setup check: a full run does rewrite the stale row, so the line above can fail.
        try await runtime.scheduler.runFull()
        #expect(try await cadenceRow(zoe) != stale)
        let pending = try await environment.reminders.fetchAllPending().sorted { $0.id.uuidString < $1.id.uuidString }
        try await runtime.scheduler.runFull()
        let afterFull = try await environment.reminders.fetchAllPending().sorted { $0.id.uuidString < $1.id.uuidString }
        #expect(afterFull == pending, "A second full run is a no-op.")
    }

    /// A failed run for one contact must not stop the rest: the save logs it
    /// and goes on, and the next foreground full run repairs the one that failed.
    @Test("When the pass fails for one saved contact, the other is still scheduled and the save succeeds")
    @MainActor
    func settingsStarterSaveReschedulesRemainingContactsWhenOneRunThrows() async throws {
        let base = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let probe = try await Self.fixedClockRuntime(base)
        let longAgo = probe.clock().addingTimeInterval(-100 * 86_400)
        let ana = Contact(systemContactRef: "starter-ana", displayName: "Ana", lastInteractedAt: longAgo)
        let ben = Contact(systemContactRef: "starter-ben", displayName: "Ben", lastInteractedAt: longAgo)
        for contact in [ana, ben] { try await base.contacts.upsert(contact) }
        // Writes of Ana's reminder row fail; everything else is the real store.
        let environment = AppEnvironment(
            contacts: base.contacts, groups: base.groups,
            reminders: CountingReminderRepository(base.reminders, failUpsertsForContact: ana.id),
            interactions: base.interactions, window: base.window, profile: base.profile)
        let runtime = try await Self.fixedClockRuntime(environment)
        let picker = RegardsTabRoot.makeStarterContactsViewModel(runtime: runtime)
        await picker.load()
        picker.toggle(ana.id)
        picker.toggle(ben.id)

        let saved = await picker.save()

        #expect(saved, "A failed reschedule is logged, not shown: the tracking writes landed.")
        let tracked = try await base.contacts.fetchAll().filter(\.tracked).map(\.id)
        #expect(Set(tracked) == [ana.id, ben.id])
        #expect(try await base.reminders.fetchPending(forContact: ana.id).isEmpty, "Ana's run threw.")
        #expect(
            try await base.reminders.fetchPending(forContact: ben.id).contains { $0.kind == .cadence },
            "Ben is rescheduled although Ana's run came first and threw."
        )
    }

    /// A runtime with a fixed clock (2026-09-21 UTC) and an explicit UTC
    /// calendar over `environment`, with no occasions.
    private static func fixedClockRuntime(_ environment: AppEnvironment) async throws -> AppRuntime {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        return AppRuntime(
            environment: environment,
            window: try await environment.window.fetchGlobal(),
            userCalendar: calendar,
            clock: { now },
            occasions: { _ in [] }
        )
    }

    @Test("Production runtime propagates a missing persisted window")
    func productionRuntimeRejectsMissingWindow() async throws {
        let environment = environment(window: StubReminderWindowRepository.missing())

        do {
            _ = try await AppRuntime.makeProduction(environment: environment)
            Issue.record("Expected the missing singleton to fail production composition")
        } catch DataError.notFound {
            // Expected: launch owns the visible recovery path in TF-02.
        } catch {
            Issue.record("Expected DataError.notFound, got \(error)")
        }
    }

    @Test("Production runtime rejects an invalid persisted window")
    func productionRuntimeRejectsInvalidWindow() async throws {
        let environment = environment(
            window: StubReminderWindowRepository.invalidTimezone("Not/A_Timezone")
        )

        do {
            _ = try await AppRuntime.makeProduction(environment: environment)
            Issue.record("Expected the invalid singleton to fail production composition")
        } catch ReminderWindow.ValidationError.invalidTimezoneIdentifier("Not/A_Timezone") {
            // Expected: corrupt timing state must never silently change zones.
        } catch {
            Issue.record("Expected invalidTimezoneIdentifier, got \(error)")
        }
    }

    @Test("A defensive ready-without-runtime state retries production launch")
    @MainActor
    func readyWithoutRuntimeRetryStartsProductionRuntime() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let runtimeFactory = SuccessfulRuntimeFactory(environment: environment)
        let launch = AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: { try await runtimeFactory.makeRuntime() },
                contactsSource: NotDeterminedContactsSource(),
                clock: { Date(timeIntervalSince1970: 1_785_600_000) }
            ),
            testingPhase: .ready
        )

        await launch.retry()

        #expect(launch.phase == .onboarding)
        #expect(launch.runtime != nil)
        #expect(await runtimeFactory.attemptCount() == 1)
    }

    /// `start()` runs the pass before the coordinator flips to `.ready`, so
    /// the tab root's first Upcoming load already has the seed cast's
    /// birthday and anniversary. Born `.ready`, the first load raced the pass
    /// and could show neither.
    @Test("The mock launch's first Upcoming load includes the seed cast's birthday and anniversary")
    @MainActor
    func mockLaunchFirstUpcomingLoadHasOccasions() async throws {
        let coordinator = AppLaunchCoordinator(mockRuntime: .makeMock(), notifications: nil)
        #expect(coordinator.phase == .loading)

        await coordinator.start()

        #expect(coordinator.phase == .ready)
        let viewModel = RegardsTabRoot.makeUpcomingViewModel(runtime: try #require(coordinator.runtime))
        await viewModel.load()
        let kinds = Set(viewModel.groups.flatMap(\.rows).map(\.kind))
        #expect(kinds.isSuperset(of: [.birthday, .anniversary]))
    }

    /// The runtime freezes time at `MockRepositories.defaultNow`. The launch's
    /// notification fake has to read that same clock: on the real one, a
    /// request 60 s after the frozen now is already due, so it never shows up
    /// as pending.
    @Test("The mock launch's notification fake lists a request due 60 s after the frozen now")
    @MainActor
    func mockLaunchNotificationFakeUsesTheFrozenClock() async throws {
        let launch = AppLaunchCoordinator.mockRuntimeLaunch(environment: [:])
        let notifications = try #require(launch.notifications)
        let request = ReminderNotificationRequest(
            identifier: "digest-frozen-clock", title: "", body: "3 people are overdue.",
            fireDate: MockRepositories.defaultNow.addingTimeInterval(60), kind: .digest
        )

        try await notifications.schedule(request)

        #expect(await notifications.pendingRequests() == [request])
    }

    private func environment(window: any ReminderWindowRepository) -> AppEnvironment {
        let base = AppEnvironment.makeMock()
        return AppEnvironment(
            contacts: base.contacts,
            groups: base.groups,
            reminders: base.reminders,
            interactions: base.interactions,
            window: window,
            profile: base.profile
        )
    }
}

private actor SuccessfulRuntimeFactory {
    private let environment: AppEnvironment
    private var attempts = 0

    init(environment: AppEnvironment) { self.environment = environment }

    func makeRuntime() async throws -> AppRuntime {
        attempts += 1
        return try await AppRuntime.makeProduction(environment: environment)
    }

    func attemptCount() -> Int { attempts }
}

private struct NotDeterminedContactsSource: ContactsSource {
    func currentAuthorization() async -> ContactsAuthorizationStatus { .notDetermined }
    func requestAccess() async throws -> ContactsAuthorizationStatus { .notDetermined }
    func fetchAllContacts() async throws -> [SystemContact] { [] }
}
