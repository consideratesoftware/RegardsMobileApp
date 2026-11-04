import Foundation
import Testing
@testable import Regards

/// R57 / PR #71. Slice 4's diff against `pendingRequests()` depends on the
/// fakes answering like the real center. Both fakes store each request through
/// the adapter's `makeRequest` and `decode` with an injected clock. These tests
/// pin that add-time delivery, read-time delivery, whole-second truncation,
/// replace by identifier and cancel match the real center, and every case runs
/// against both fakes.
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
        body: String = "It has been a while since you talked to Ada.",
        fireDate: Date
    ) -> ReminderNotificationRequest {
        ReminderNotificationRequest(
            identifier: id,
            title: "Time to reach out",
            body: body,
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
        if fake == .scripted {
            let scripted = try #require(scheduling as? ScriptedNotifications)
            #expect(await scripted.delivered.isEmpty)
        }
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
        if fake == .scripted {
            let scripted = try #require(scheduling as? ScriptedNotifications)
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

    @Test("A pending request is delivered once the clock reaches its time", arguments: Fake.allCases)
    func pendingRequestIsDeliveredOnceItsTimePasses(_ fake: Fake) async throws {
        let clock = MutableClock(Self.now)
        let scheduling = fake.make(clock: { clock.now() })
        let sent = Self.request(fireDate: Self.now.addingTimeInterval(60))
        try await scheduling.schedule(sent)
        #expect(await scheduling.pendingRequests() == [sent])

        clock.advance(by: 60)

        #expect(await scheduling.pendingRequests().isEmpty)
        if fake == .scripted {
            let scripted = try #require(scheduling as? ScriptedNotifications)
            #expect(await scripted.delivered == [sent])
        }
    }

    @Test("Cancel removes only the named pending requests and ignores unknown ids", arguments: Fake.allCases)
    func cancelRemovesOnlyTheNamedPendingRequests(_ fake: Fake) async throws {
        let now = Self.now
        let scheduling = fake.make(clock: { now })
        try await scheduling.schedule(Self.request(id: "a", fireDate: now.addingTimeInterval(3600)))
        try await scheduling.schedule(Self.request(id: "b", fireDate: now.addingTimeInterval(3600)))

        await scheduling.cancel(identifiers: ["a", "missing"])
        #expect(await scheduling.pendingRequests().map(\.identifier) == ["b"])

        await scheduling.cancel(identifiers: ["b"])
        #expect(await scheduling.pendingRequests().isEmpty)
    }

    @Test("A future add replaces the pending request with the same identifier", arguments: Fake.allCases)
    func futureAddReplacesPendingWithSameIdentifier(_ fake: Fake) async throws {
        let now = Self.now
        let scheduling = fake.make(clock: { now })
        try await scheduling.schedule(Self.request(id: "x", body: "first", fireDate: now.addingTimeInterval(3600)))
        let second = Self.request(id: "x", body: "second", fireDate: now.addingTimeInterval(7200))

        try await scheduling.schedule(second)

        #expect(await scheduling.pendingRequests() == [second])
    }
}
