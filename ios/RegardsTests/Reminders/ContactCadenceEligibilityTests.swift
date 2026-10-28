import Foundation
import Testing
@testable import Regards

/// `Contact.isCadenceEligible` is the one predicate behind cadence reminders,
/// Snooze, and the Contact Detail window row: active, tracked, and a cadence of
/// at least 1 day.
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
}
