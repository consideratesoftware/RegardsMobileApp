import Foundation
import Testing
@testable import Regards

/// The Contact Detail "Reminder window" row and its Change button exist only
/// for a contact that can have a cadence reminder: tracked, with a cadence,
/// and not archived (the same gate Snooze uses). A window means nothing for
/// any other contact.
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
        case archived

        var testDescription: String { rawValue }

        var canEdit: Bool { self == .trackedWithCadence }

        func contact() -> Contact {
            Contact(
                systemContactRef: "window-gate-\(rawValue)",
                displayName: "Gate \(rawValue)",
                tracked: self != .untrackedWithCadence,
                cadenceDays: self == .trackedWithoutCadence ? nil : 14,
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
            scheduler: SchedulingPass(reminders: StubReminderRepository(), contacts: contacts, clock: { gateNow }),
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
            scheduler: SchedulingPass(reminders: StubReminderRepository(), contacts: contacts, clock: { gateNow }),
            clock: { gateNow }
        )

        #expect(!viewModel.canEditReminderWindow)
    }
}
