import Foundation
import Testing
@testable import Regards

struct MockRepositoriesTests {

    @Test("Representative states use stable Upcoming identities")
    @MainActor
    func representativeStatesAndStableUpcomingIDs() async throws {
        let now = MockRepositories.defaultNow
        let mocks = MockRepositories(now: now)

        let groups = try await mocks.groups.fetchAll()
        let group = try #require(groups.first)
        let primary = try #require(
            try await mocks.contacts.fetch(id: group.primaryContactId)
        )
        let members = try await mocks.contacts.fetchMembers(ofGroup: group.id)
        #expect(members.count == 2)
        #expect(primary.contactGroupId == group.id)
        #expect(members.contains(where: { !$0.isActive }))

        let interactions = try await mocks.interactions.fetchRecent(
            forContact: primary.id,
            limit: 8
        )
        #expect(interactions.count == 2)
        #expect(interactions.map(\.source) == [.reminderCaughtUp, .manual])

        let reminders = try await mocks.reminders.fetchAllPending()
        #expect(Set(reminders.map(\.kind)) == [.birthday, .anniversary])

        let timezone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let viewModel = UpcomingViewModel(
            contacts: mocks.contacts,
            reminders: mocks.reminders,
            window: .defaultV1(timezone: timezone),
            clock: { now }
        )

        await viewModel.load()
        let firstRows = viewModel.groups.flatMap(\.rows)
        let firstIDs = Set(firstRows.map(\.id))
        #expect(firstRows.contains(where: { $0.kind == .birthday }))
        #expect(firstRows.contains(where: { $0.kind == .anniversary }))
        #expect(firstRows.allSatisfy {
            $0.id.contactId == $0.contactId && $0.id.kind == $0.kind
        })

        await viewModel.load()
        let secondIDs = Set(viewModel.groups.flatMap(\.rows).map(\.id))
        #expect(secondIDs == firstIDs)

        let overdueRow = try #require(
            OverdueViewModel.makeOverdueRow(
                for: primary,
                now: now,
                calendar: Calendar(identifier: .gregorian)
            )
        )
        #expect(overdueRow.isVirtualMerged)
        #expect(overdueRow.accessibilityLabel.contains("merged contact"))
    }
}
