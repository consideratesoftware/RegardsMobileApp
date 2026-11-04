import Foundation
import Testing
@testable import Regards

/// R57 / PR #71. The 2 `NotificationScheduling` fakes must answer the 2 reads
/// slice 4's diff-against-`pendingRequests()` logic depends on the way the real
/// center does: a pending fire date is whole-second, and a request whose
/// trigger instant is not after now is delivered at once, never pending.
/// Both fakes get their clock through the same closure, and every case runs
/// against both, so they can't drift apart.
///
/// The truncation and delivery rules come from the adapter's own `makeRequest`
/// and `decode`, which `UserNotificationsAdapterRequestTests` pins. These tests
/// pin that the fakes use them.
struct NotificationFakeParityTests {
    enum Fake: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case scripted
        case debug

        var testDescription: String { rawValue }

        func make(clock: @escaping @Sendable () -> Date) -> any NotificationScheduling {
            switch self {
            case .scripted: ScriptedNotifications(clock: clock)
            case .debug: DebugNotificationScheduling(clock: clock)
            }
        }
    }

    /// A whole second, so the cases below can name sub-second offsets from it.
    private static let now = Date(timeIntervalSince1970: 1_785_600_000)

    private static func request(
        id: String = "contact-5C1F0E52-8A3B-4D7E-9B1A-0C2D3E4F5A6B-cadence",
        fireDate: Date
    ) -> ReminderNotificationRequest {
        ReminderNotificationRequest(
            identifier: id,
            title: "Time to reach out",
            body: "It has been a while since you talked to Ada.",
            fireDate: fireDate,
            contactId: UUID(uuidString: "5C1F0E52-8A3B-4D7E-9B1A-0C2D3E4F5A6B"),
            category: .cadence
        )
    }

    @Test("A future request is pending at its whole second, with every other field equal", arguments: Fake.allCases)
    func futureRequestIsPendingAtWholeSeconds(_ fake: Fake) async throws {
        let now = Self.now
        let scheduling = fake.make(clock: { now })
        let sent = Self.request(fireDate: now.addingTimeInterval(60.7))

        try await scheduling.schedule(sent)

        let expected = Self.request(fireDate: now.addingTimeInterval(60))
        #expect(await scheduling.pendingRequests() == [expected])
    }

    @Test(
        "A request not after now is not pending",
        arguments: Fake.allCases, [0.0, -1.0, 0.4]
    )
    func requestNotAfterNowIsNotPending(_ fake: Fake, offset: TimeInterval) async throws {
        let now = Self.now
        let scheduling = fake.make(clock: { now })
        let sent = Self.request(fireDate: now.addingTimeInterval(offset))

        try await scheduling.schedule(sent)

        #expect(await scheduling.pendingRequests().isEmpty)
        if let scripted = scheduling as? ScriptedNotifications {
            #expect(await scripted.delivered == [sent])
        }
    }

    @Test("An immediate add replaces a pending request with the same identifier", arguments: Fake.allCases)
    func immediateAddReplacesAPendingRequest(_ fake: Fake) async throws {
        let now = Self.now
        let scheduling = fake.make(clock: { now })

        try await scheduling.schedule(Self.request(fireDate: now.addingTimeInterval(3600)))
        #expect(await scheduling.pendingRequests().count == 1)
        try await scheduling.schedule(Self.request(fireDate: now.addingTimeInterval(-1)))

        #expect(await scheduling.pendingRequests().isEmpty)
    }
}
