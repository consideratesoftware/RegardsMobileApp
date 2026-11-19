import Foundation
import Testing
@testable import Regards

/// A refused mark (§9 "Notification fired", §9a Run invariant). Split from
/// `SchedulingPassFiredRowTests`, which sits at SwiftLint's type-length limit.
extension SchedulingPassFiredRowTests {

    /// A mark returns false only when a writer outside the pass lock moved the row first. The run skips that
    /// mark and goes on: it marks every later due row, does not throw, derives the refused row from its
    /// snapshot, leaves no covered pending row due, and cancels no due row. The false return comes from the
    /// real backend's compare-and-set (`raceNextMark`), never from a fake that leaves the row pending.
    @Test(
        "A refused mark does not stop the run, and no due row is cancelled",
        arguments: RepositoryContractBackend.allCases, [ReminderState.fired, .cancelled]
    )
    func refusedMarkDoesNotStopTheRun(backend: RepositoryContractBackend, race: ReminderState) async throws {
        let fixture = try await PassFixture(backend: backend)
        _ = try await fixture.addContact(1)
        _ = try await fixture.addContact(2)
        try await fixture.pass.runFull()
        fixture.setNow("2026-06-10 18:30")
        let now = fixture.clock.now()
        let due = try await fixture.repositories.reminders.fetchAllPending().filter { $0.scheduledFor <= now }
        try #require(due.count >= 2)

        await fixture.reminders.raceNextMark(to: race)
        try await fixture.pass.runFull()

        let marks = await fixture.reminders.transitionLog.filter { $0.from == .pending && $0.to == .fired }
        #expect(marks.count >= 2)
        #expect(marks.first?.applied == false)
        #expect(marks.dropFirst().allSatisfy { $0.applied })
        for row in due {
            var fired = row
            fired.state = .fired
            #expect(try await fixture.row(row.id) == fired, "row \(row.id) (refused: \(row.id == marks.first?.id))")
        }
        let log = await fixture.reminders.transitionLog
        #expect(log.allSatisfy { !($0.to == .cancelled && $0.applied) })
        let stillDue = try await fixture.repositories.reminders.fetchAllPending().filter { $0.scheduledFor <= now }
        #expect(stillDue.isEmpty)
        let writes = await fixture.reminders.writeCount
        try await fixture.pass.runFull()
        #expect(await fixture.reminders.writeCount == writes)
    }
}
