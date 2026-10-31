import Foundation
import Testing
@testable import Regards

/// `Contact.isCadenceEligible` gates Snooze, the Contact Detail window row,
/// and the cadence rows `SchedulingPass` writes: active, tracked, and a
/// cadence of at least 1 day. The pass must write a cadence row for exactly
/// the cases below that the property accepts.
struct ContactCadenceEligibilityTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let tracked: Bool
        let cadenceDays: Int?
        let archived: Bool
        let expected: Bool

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "tracked, 1 day", tracked: true, cadenceDays: 1, archived: false, expected: true),
        Case(name: "tracked, 365 days", tracked: true, cadenceDays: 365, archived: false, expected: true),
        Case(name: "tracked, 0 days", tracked: true, cadenceDays: 0, archived: false, expected: false),
        Case(name: "tracked, -1 days", tracked: true, cadenceDays: -1, archived: false, expected: false),
        Case(name: "tracked, no cadence", tracked: true, cadenceDays: nil, archived: false, expected: false),
        Case(name: "untracked, 7 days", tracked: false, cadenceDays: 7, archived: false, expected: false),
        Case(name: "archived and tracked, 7 days", tracked: true, cadenceDays: 7, archived: true, expected: false),
    ]

    @Test("A contact gets cadence reminders only when active, tracked, and cadence is at least 1 day",
          arguments: cases)
    func isCadenceEligibleTruthTable(scenario: Case) {
        let contact = Contact(
            systemContactRef: "eligibility-\(scenario.name)",
            displayName: "Eligibility",
            tracked: scenario.tracked,
            cadenceDays: scenario.cadenceDays,
            archivedAt: scenario.archived ? Date(timeIntervalSince1970: 1_800_000_000) : nil
        )

        #expect(contact.isCadenceEligible == scenario.expected)
    }

    /// The pass gives every eligible contact a row, due or not (the 365-day
    /// case is due in 2027), so whether a row exists is the pass's answer.
    @Test("runFull writes a cadence row for exactly the contacts isCadenceEligible accepts",
          arguments: cases, RepositoryContractBackend.allCases)
    func passWritesCadenceRowExactlyForEligibleContacts(
        scenario: Case,
        backend: RepositoryContractBackend
    ) async throws {
        let fixture = try await PassFixture(backend: backend)
        let contact = try await fixture.addContact(
            1, cadenceDays: scenario.cadenceDays, tracked: scenario.tracked)
        if scenario.archived {
            try await fixture.repositories.contacts.archive(id: contact.id, at: PassFixture.at("2026-06-01 10:00"))
        }

        try await fixture.pass.runFull()

        #expect((try await fixture.cadenceRow(contact) != nil) == scenario.expected)
    }
}
