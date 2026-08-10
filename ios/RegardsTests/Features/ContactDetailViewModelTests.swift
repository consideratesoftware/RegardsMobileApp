import Foundation
import Testing
@testable import Regards

/// Load, failure, derived-string, and action coverage for
/// `ContactDetailViewModel` (R24 — this VM previously had only
/// `ContactDetailInteractionLabelTests`' spoken-label coverage). The action
/// tests (`markCaughtUp`, `logOther`) lock in ARCHITECTURE.md §14 PR22: both
/// persist through `ContactRepository`/`InteractionRepository` only, never
/// touching `ScheduledReminder` (decision #36).
@MainActor
struct ContactDetailViewModelTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func contact(
        id: UUID = UUID(),
        priorityTier: PriorityTier = .close,
        cadenceDays: Int? = 14,
        preferredChannel: Channel = .whatsapp,
        lastInteractedAt: Date? = nil,
        createdAt: Date = now.addingTimeInterval(-100 * 86_400)
    ) -> Contact {
        Contact(
            id: id,
            systemContactRef: "sys-\(id.uuidString)",
            displayName: "Leia Organa",
            tracked: true,
            cadenceDays: cadenceDays,
            priorityTier: priorityTier,
            preferredChannel: preferredChannel,
            preferredChannelValue: "+14155550140",
            lastInteractedAt: lastInteractedAt,
            createdAt: createdAt
        )
    }

    // MARK: - Load

    @Test("A successful load exposes the contact and its recent interactions")
    func loadExposesContactAndInteractions() async throws {
        let contact = Self.contact()
        let log = InteractionLog(
            contactId: contact.id,
            occurredAt: Self.now.addingTimeInterval(-86_400),
            source: .manual,
            channel: .phoneCall
        )
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository([log]),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.contact?.id == contact.id)
        #expect(viewModel.interactions.count == 1)
        #expect(viewModel.interactions[0].id == log.id)
    }

    @Test("A failing contact fetch clears contact and interactions")
    func failedLoadClearsState() async throws {
        let viewModel = ContactDetailViewModel(
            contactId: UUID(),
            contacts: StubContactRepository.failing(),
            interactionsRepo: StubInteractionRepository(),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.contact == nil)
        #expect(viewModel.interactions.isEmpty)
    }

    @Test("A failing interaction fetch clears contact and interactions even though the contact read succeeded")
    func failedInteractionFetchClearsState() async throws {
        let contact = Self.contact()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository.failing(),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.contact == nil)
        #expect(viewModel.interactions.isEmpty)
    }

    // MARK: - Derived strings

    @Test(
        "priorityLabel maps every tier to its spoken phrase",
        arguments: [
            (PriorityTier.innerCircle, "inner circle"),
            (PriorityTier.close, "close friend"),
            (PriorityTier.regular, "regular"),
            (PriorityTier.acquaintance, "acquaintance"),
        ]
    )
    func priorityLabelMapsEveryTier(tier: PriorityTier, expected: String) async throws {
        let contact = Self.contact(priorityTier: tier)
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository(),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.priorityLabel == expected)
    }

    @Test("cadenceLabel reports 'not tracked' when the contact has no cadence")
    func cadenceLabelReportsNotTracked() async throws {
        let contact = Self.contact(cadenceDays: nil)
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository(),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.cadenceLabel == "not tracked")
    }

    @Test("lastTalkedLabel reports 'never' when the contact has no interaction")
    func lastTalkedLabelReportsNever() async throws {
        let contact = Self.contact(lastInteractedAt: nil)
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository(),
            clock: { Self.now }
        )

        await viewModel.load()

        #expect(viewModel.lastTalkedLabel == "never")
    }

    @Test("overdueSummary reports overdue days once the cadence has elapsed")
    func overdueSummaryReportsOverdueDays() async throws {
        let contact = Self.contact(cadenceDays: 7, lastInteractedAt: Self.now.addingTimeInterval(-10 * 86_400))
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository(),
            clock: { Self.now },
            calendar: {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
                return calendar
            }()
        )

        await viewModel.load()

        #expect(viewModel.overdueSummary.isOverdue)
        #expect(viewModel.overdueSummary.days == 3)
    }

    // MARK: - Actions (R11 / PR22)

    @Test("Caught up logs the interaction against the preferred channel and moves lastInteractedAt")
    func markCaughtUpPersistsAndReloads() async throws {
        let contact = Self.contact(preferredChannel: .signal, lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.markCaughtUp()

        #expect(viewModel.contact?.lastInteractedAt == Self.now)
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)
        #expect(logs[0].channel == .signal)
        #expect(viewModel.interactions.count == 1)
    }

    @Test("Log other logs the interaction against the chosen channel, not the preferred one")
    func logOtherPersistsChosenChannel() async throws {
        let contact = Self.contact(preferredChannel: .whatsapp, lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: interactions,
            clock: { Self.now }
        )
        await viewModel.load()

        await viewModel.logOther(channel: .email)

        #expect(viewModel.contact?.lastInteractedAt == Self.now)
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .manual)
        #expect(logs[0].channel == .email)
    }

    @Test("A failing action leaves the view model's loaded state untouched")
    func failingActionLeavesStateUntouched() async throws {
        let contact = Self.contact(lastInteractedAt: nil)
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: StubContactRepository([contact]),
            interactionsRepo: StubInteractionRepository.failing(),
            clock: { Self.now }
        )
        await viewModel.load()
        #expect(viewModel.contact == nil) // the failing interaction fetch already cleared it

        await viewModel.markCaughtUp()

        // No crash, and the failed action doesn't fabricate a contact.
        #expect(viewModel.contact == nil)
    }
}
