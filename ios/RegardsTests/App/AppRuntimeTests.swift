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
    func productionRuntimeDoesNotRetainMockTiming() throws {
        let runtime = AppRuntime.makeProduction(
            database: try DatabaseFactory.makeInMemoryDatabase()
        )
        let liveNow = Date()

        #expect(abs(runtime.clock().timeIntervalSince(liveNow)) < 5)
        #expect(runtime.window.timeZone.identifier == TimeZone.current.identifier)
        #expect(runtime.clock() != MockRepositories.defaultNow)
    }
}
