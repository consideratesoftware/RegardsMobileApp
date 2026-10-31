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
    /// starter picker's save reaches the runtime's one pass, so an untracked
    /// contact's pending row is cancelled and a newly tracked one is
    /// scheduled before the screen closes. The production runtime uses the real
    /// clock, so both contacts are long overdue rather than due at a set time.
    @Test("The Settings starter picker schedules and cancels through the pass, and a second full run changes nothing")
    @MainActor
    func settingsStarterPickerSchedulesAndCancelsThroughThePass() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let longAgo = Date(timeIntervalSince1970: 1_600_000_000)
        let xena = Contact(
            systemContactRef: "starter-xena", displayName: "Xena",
            tracked: true, cadenceDays: 7, lastInteractedAt: longAgo)
        let yara = Contact(systemContactRef: "starter-yara", displayName: "Yara", lastInteractedAt: longAgo)
        try await environment.contacts.upsert(xena)
        try await environment.contacts.upsert(yara)
        let runtime = try await AppRuntime.makeProduction(environment: environment)
        try await runtime.scheduler.runFull()
        func hasCadenceRow(_ contact: Contact) async throws -> Bool {
            try await environment.reminders.fetchPending(forContact: contact.id).contains { $0.kind == .cadence }
        }
        #expect(try await hasCadenceRow(xena), "Setup: the tracked contact is scheduled.")
        #expect(try await hasCadenceRow(yara) == false)
        let picker = RegardsTabRoot.makeStarterContactsViewModel(runtime: runtime)
        await picker.load()
        picker.toggle(xena.id)
        picker.toggle(yara.id)

        #expect(await picker.save())

        #expect(try await hasCadenceRow(xena) == false, "Untracking cancels the pending row.")
        #expect(try await hasCadenceRow(yara), "Tracking schedules a row.")
        let pending = try await environment.reminders.fetchAllPending().sorted { $0.id.uuidString < $1.id.uuidString }
        try await runtime.scheduler.runFull()
        let afterFull = try await environment.reminders.fetchAllPending().sorted { $0.id.uuidString < $1.id.uuidString }
        #expect(afterFull == pending, "A second full run is a no-op.")
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
