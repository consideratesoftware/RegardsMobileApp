import Foundation
import Testing
@testable import Regards

/// The documented §9 contract-6 deviation and the zoom-transition source it
/// forced.
///
/// Split out of `UpcomingViewModelStateTests` to keep that suite under the
/// type-body-length limit. Everything here is about one contact holding more
/// than one row: that a same-day cadence + occasion pair stays visible with
/// distinct identities until `SchedulingPass` owns suppression (PR25 / TF-07,
/// R6), and that exactly one of those rows may declare the zoom source.
@MainActor
struct UpcomingViewModelDuplicateRowTests {

    @Test("A same-day cadence and occasion pair produces two distinct rows")
    func sameDayCadenceAndOccasionBothAppear() async throws {
        // §9 contract 6 says the occasion should suppress the cadence
        // reminder. `SchedulingPass` owns that rule (PR25 / TF-07, R6) and it
        // is documented as unenforced here. This test pins the current
        // behavior so the deviation is visible rather than silent: both rows
        // appear, and — critically — their IDs do not collide, so the
        // duplicate cannot corrupt identity, diffing, or ordering while it
        // lasts. TF-07 will replace this expectation with suppression.
        let contact = UpcomingFixtures.contact(
            systemRef: "same-day-double-up",
            displayName: "Padmé Amidala",
            cadenceDays: 1
        )
        let occasion = ScheduledReminder(
            contactId: contact.id,
            kind: .birthday,
            scheduledFor: UpcomingFixtures.now.addingTimeInterval(3_600),
            osNotificationId: "same-day-double-up-occasion"
        )
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository([occasion]),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        let forContact = rows.filter { $0.contactId == contact.id }
        #expect(forContact.count == 2)
        #expect(Set(forContact.map(\.kind)) == [.cadence, .birthday])
        #expect(Set(forContact.map(\.id)).count == 2)

        // Both land on the same local calendar day, which is what makes this
        // the contract-6 case rather than two unrelated rows.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = UpcomingFixtures.utc
        let days = Set(forContact.map { calendar.startOfDay(for: $0.scheduledFor) })
        #expect(days.count == 1)

        // Exactly one of the two may declare the zoom-transition source, or
        // the duplicate contact id is registered twice in one namespace and
        // the animation resolves against an arbitrary row.
        let owners = viewModel.transitionSourceRowIDs
        #expect(forContact.filter { owners.contains($0.id) }.count == 1)
    }

    @Test("Every contact owns exactly one transition source")
    func everyContactOwnsOneTransitionSource() async throws {
        let first = UpcomingFixtures.contact(
            systemRef: "transition-first",
            displayName: "Leia Organa",
            cadenceDays: 1
        )
        let second = UpcomingFixtures.contact(
            systemRef: "transition-second",
            displayName: "Luke Skywalker",
            cadenceDays: 1
        )
        let occasions = [first, second].enumerated().map { index, contact in
            ScheduledReminder(
                contactId: contact.id,
                kind: .birthday,
                scheduledFor: UpcomingFixtures.now.addingTimeInterval(TimeInterval(3_600 * (index + 1))),
                osNotificationId: "transition-occasion-\(index)"
            )
        }
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([first, second]),
            reminders: StubReminderRepository(occasions),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        let owners = viewModel.transitionSourceRowIDs
        #expect(rows.count > owners.count)
        #expect(owners.count == 2)
        for contactId in [first.id, second.id] {
            let owned = rows.filter { $0.contactId == contactId && owners.contains($0.id) }
            #expect(owned.count == 1)
        }
    }

    @Test("One owner survives when a contact's rows land in different day groups")
    func transitionOwnerHoldsAcrossDayGroups() async throws {
        // The shipped fixture shape: a contact's cadence row falls on one day
        // and its occasion on another, so the two rows sit in different
        // sections. Grouping must not hand each section its own owner.
        let contact = UpcomingFixtures.contact(
            systemRef: "cross-day-owner",
            displayName: "Obi-Wan Kenobi",
            cadenceDays: 1
        )
        let laterOccasion = ScheduledReminder(
            contactId: contact.id,
            kind: .anniversary,
            scheduledFor: UpcomingFixtures.now.addingTimeInterval(4 * 86_400),
            osNotificationId: "cross-day-occasion"
        )
        let viewModel = UpcomingViewModel(
            contacts: StubContactRepository([contact]),
            reminders: StubReminderRepository([laterOccasion]),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { UpcomingFixtures.now }
        )

        await viewModel.load()

        let rows = viewModel.groups.flatMap(\.rows)
        #expect(rows.count == 2)
        #expect(viewModel.groups.count == 2)
        let owners = viewModel.transitionSourceRowIDs
        #expect(rows.filter { owners.contains($0.id) }.count == 1)

        // The non-owning row still carries the contact id, so its tap target
        // is unaffected — only the zoom source is elected.
        #expect(rows.allSatisfy { $0.contactId == contact.id })
    }
}
