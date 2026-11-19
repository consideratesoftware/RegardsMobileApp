import Foundation
import Testing
@testable import Regards

/// What `run(for:)` leaves alone (TF-07e, §9 "Notification fired"). Dates are
/// New York local times (`PassFixture`); the clock starts at 2026-06-10 10:00.
struct SchedulingPassRunForScopeTests {

    /// Two contacts each have a pending cadence row whose time passed an hour
    /// ago. A run for the first contact marks only its row fired; the second
    /// contact's row is outside the run, so it stays pending and unchanged
    /// until a full run covers it.
    @Test(
        "run(for:) marks only that contact's due row fired and leaves another contact's due row pending",
        arguments: RepositoryContractBackend.allCases
    )
    func runForOneContactMarksOnlyThatContactsDueRowFired(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend)
        let first = try await fixture.addContact(1)
        let second = try await fixture.addContact(2)
        let dueAt = fixture.clock.now().addingTimeInterval(-3_600)
        // Both contacts have been overdue since 05-08 10:00 (the 05-01 10:00 interaction plus 7 days).
        let dueRows = [first, second].map {
            ScheduledReminder(
                id: fixture.cadenceID($0),
                contactId: $0.id,
                kind: .cadence,
                scheduledFor: dueAt,
                osNotificationId: "contact-\($0.id.uuidString)-cadence",
                firedCycle: PassFixture.at("2026-05-08 10:00"))
        }
        for row in dueRows { try await fixture.repositories.reminders.upsert(row) }
        var firedFirst = dueRows[0]
        firedFirst.state = .fired
        var firedSecond = dueRows[1]
        firedSecond.state = .fired

        try await fixture.pass.run(for: first.id)

        #expect(try await fixture.row(dueRows[0].id) == firedFirst)
        #expect(try await fixture.row(dueRows[1].id) == dueRows[1])

        try await fixture.pass.runFull()

        #expect(try await fixture.row(dueRows[0].id) == firedFirst)
        #expect(try await fixture.row(dueRows[1].id) == firedSecond)
    }
}
