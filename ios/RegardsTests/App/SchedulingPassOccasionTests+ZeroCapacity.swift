import Foundation
import Testing
@testable import Regards

/// Occasion rows for a contact whose window has no cadence capacity (R4, §9 contracts 2 and 4), and the
/// fired row of an occasion that never notifies. In an extension only to keep `SchedulingPassOccasionTests`
/// under `type_body_length`; it shares that suite's `birthdays` provider and `quietEvenings`.
extension SchedulingPassOccasionTests {

    struct ZeroCapacityShape: Sendable, CustomTestStringConvertible {
        let name: String
        let window: ReminderWindow

        var testDescription: String { name }
    }

    /// The repositories refuse a window with no allowed days or no ranges (`validate()`), so every stored
    /// zero-capacity window is valid with quiet hours covering each range.
    static let zeroCapacityShapes = [
        // Quiet hours 17:00-20:00 cover the whole 18:00-19:00 range.
        ZeroCapacityShape(
            name: "quiet hours inside the day cover the range",
            window: PassFixture.eveningWindow(quiet: TimeRange(start: TimeOfDay(hour: 17), end: TimeOfDay(hour: 20)))),
        // Quiet hours 22:30-07:30 wrap midnight and cover the whole 01:00-06:00 range.
        ZeroCapacityShape(
            name: "quiet hours that wrap midnight cover the range",
            window: PassFixture.eveningWindow(start: 1, end: 6, quiet: quietEvenings)),
    ]

    /// Capacity applies to cadence only. An occasion is subject to quiet hours alone (§9 contract 4), so a
    /// contact whose window can never fire a cadence reminder keeps its birthday row at the occasion time.
    @Test(
        "A contact whose window has no cadence capacity still gets its occasion row",
        arguments: RepositoryContractBackend.allCases, zeroCapacityShapes
    )
    func zeroCapacityContactKeepsOccasionRows(
        backend: RepositoryContractBackend, shape: ZeroCapacityShape
    ) async throws {
        let fixture = try await PassFixture(backend: backend, occasions: try Self.birthdays(for: [1]))
        let contact = try await fixture.addContact(1, override: shape.window)

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(row.scheduledFor == PassFixture.at("2026-06-12 09:00"))
        #expect(row.state == .pending)
        #expect(try await fixture.cadenceRow(contact) == nil)
        #expect(await fixture.pass.zeroCapacityContactIds == [contact.id])
    }

    /// A 23:00 birthday under quiet hours 22:30-07:30 (owner ruling 9), with `now` at its occurrence. No
    /// notification time exists, but the row's time has come, so the run writes it fired (§9 "Notification
    /// fired": every row a run writes at or before now is fired). A pass that wrote it pending would have the
    /// next run mark it fired. A run 30 minutes later, with the occurrence behind it, leaves the row alone
    /// instead of moving it to the next occurrence.
    @Test(
        "A never-notifying occasion that is due now is written fired and stays put",
        arguments: RepositoryContractBackend.allCases
    )
    func neverNotifyingOccasionDueNowIsWrittenFired(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(
            backend: backend, now: "2026-06-12 23:00",
            window: PassFixture.eveningWindow(quiet: Self.quietEvenings, occasionTime: TimeOfDay(hour: 23)),
            occasions: try Self.birthdays(for: [1]))
        let contact = try await fixture.addContact(1)
        let id = SchedulingPass.reminderID(contactId: contact.id, kind: .birthday)

        try await fixture.pass.runFull()

        let written = try #require(try await fixture.row(id))
        #expect(written.scheduledFor == PassFixture.at("2026-06-12 23:00"))
        #expect(written.state == .fired)
        #expect(try await fixture.occasionRow(contact, .birthday) == nil)
        let writes = await fixture.reminders.writeCount

        try await fixture.pass.runFull()

        #expect(try await fixture.row(id) == written)
        #expect(await fixture.reminders.writeCount == writes)

        fixture.setNow("2026-06-12 23:30")
        try await fixture.pass.runFull()

        #expect(try await fixture.row(id) == written, "The fired row does not chase the clock.")
        #expect(await fixture.reminders.writeCount == writes)
    }
}
