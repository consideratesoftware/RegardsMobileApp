import Foundation
import Testing
@testable import Regards

struct AppRuntimeTests {

    @Test("App mock composition renders occasions in its own forward horizon")
    @MainActor
    func mockCompositionSharesClockAndWindow() async throws {
        let runtime = AppRuntime.makeMock()
        let viewModel = RegardsTabRoot.makeUpcomingViewModel(runtime: runtime)

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
        #expect(overdueRow.lastInteractedText == relative)
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
