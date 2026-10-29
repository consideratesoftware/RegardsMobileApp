import Foundation
import Testing
@testable import Regards

/// The Contact Detail "Reminder window" row and its Change button exist only
/// for a contact that can have a cadence reminder: tracked, with a cadence of
/// at least 1 day, and not archived (the same gate Snooze uses). A window
/// means nothing for any other contact.
///
/// The gate is `ContactDetailViewModel.canEditReminderWindow`, which the
/// Contact Detail screen reads to show the row.
private let gateNow = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
struct ContactDetailViewModelWindowGateTests {

    enum Case: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case trackedWithCadence
        case untrackedWithCadence
        case trackedWithoutCadence
        case trackedWithZeroCadence
        case archived

        var testDescription: String { rawValue }

        var canEdit: Bool { self == .trackedWithCadence }

        private var cadenceDays: Int? {
            switch self {
            case .trackedWithoutCadence: nil
            case .trackedWithZeroCadence: 0
            default: 14
            }
        }

        func contact() -> Contact {
            Contact(
                systemContactRef: "window-gate-\(rawValue)",
                displayName: "Gate \(rawValue)",
                tracked: self != .untrackedWithCadence,
                cadenceDays: cadenceDays,
                lastInteractedAt: gateNow.addingTimeInterval(-86_400),
                archivedAt: self == .archived ? gateNow.addingTimeInterval(-3_600) : nil
            )
        }
    }

    private static func loadedViewModel(for contact: Contact) async -> ContactDetailViewModel {
        let contacts = StubContactRepository([contact])
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository(),
                contacts: contacts,
                window: FixedReminderWindowRepository(),
                occasions: { _ in [] },
                clock: { gateNow }
            ),
            clock: { gateNow }
        )
        await viewModel.load()
        return viewModel
    }

    @Test("The reminder-window row is offered only for a tracked, non-archived contact with a cadence",
          arguments: Case.allCases)
    func windowRowGate(scenario: Case) async throws {
        let viewModel = await Self.loadedViewModel(for: scenario.contact())

        #expect(viewModel.canEditReminderWindow == scenario.canEdit)
    }

    @Test("Before the contact loads there is no reminder-window row")
    func noWindowRowBeforeLoad() {
        let contact = Case.trackedWithCadence.contact()
        let contacts = StubContactRepository([contact])
        let viewModel = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(
                reminders: StubReminderRepository(),
                contacts: contacts,
                window: FixedReminderWindowRepository(),
                occasions: { _ in [] },
                clock: { gateNow }
            ),
            clock: { gateNow }
        )

        #expect(!viewModel.canEditReminderWindow)
    }

    @Test("A tracked contact with a cadence of 0 days is never summarized as overdue")
    func zeroCadenceContactIsNotOverdue() async {
        let contact = Case.trackedWithZeroCadence.contact()
        let viewModel = await Self.loadedViewModel(for: contact)

        #expect(viewModel.overdueSummary.isOverdue == false)
        #expect(viewModel.overdueSummary.days == 0)
    }
}
