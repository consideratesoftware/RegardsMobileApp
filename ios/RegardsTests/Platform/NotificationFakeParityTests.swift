import Foundation
import Testing
@testable import Regards

/// R57 / PR #71. Slice 4's diff against `pendingRequests()` depends on the
/// fakes answering consistently. Both fakes store each request through the
/// adapter's `makeRequest` and `decode` with an injected clock. These tests pin
/// the fakes to those rules: add-time delivery, read-time delivery, whole-second
/// truncation, replace by identifier and cancel. They don't show the real
/// center behaves the same way; live-center behavior is left to device check
/// (a) in TESTFLIGHT_PLAN.md. Every parameterized case runs against both
/// fakes; the scripted-only cases check its delivered record.
///
/// Pending storage goes through the adapter's `makeRequest` and `decode`, which
/// `UserNotificationsAdapterRequestTests` pins. The scripted fake's delivered
/// floor is the adapter's own truncation, and the fake holds no rounding code
/// of its own. `requestWhoseWholeSecondFireDateIsNotAfterNowIsNotPending` pins
/// that floor against literal whole-second instants.
///
/// Neither fake models iOS's cap on pending requests: the system keeps at most
/// 64 per app, and the fakes keep any number. Slice 4's planner keeps its
/// desired set within the budget §9 platform nuance sets, which is below that
/// cap, and pins that with its own test. A fake cap, if slice 4 needs one,
/// arrives with that test.
struct NotificationFakeParityTests {
    // MARK: - Fakes and helpers

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

    private static let contactId = UUID(uuidString: "5C1F0E52-8A3B-4D7E-9B1A-0C2D3E4F5A6B")!

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
            kind: .cadence(contactId: contactId)
        )
    }

    // MARK: - Pending storage

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

    // MARK: - Immediate delivery

    @Test(
        "A request whose whole-second fire date is not after now is not pending",
        arguments: Fake.allCases,
        [(0.0, 0.0), (-1.0, -1.0), (0.4, 0.0), (0.6, 0.0)]
    )
    func requestWhoseWholeSecondFireDateIsNotAfterNowIsNotPending(
        _ fake: Fake, offsets: (sent: TimeInterval, wholeSecond: TimeInterval)
    ) async throws {
        let now = Self.now
        let scheduling = fake.make(clock: { now })
        let sent = Self.request(fireDate: now.addingTimeInterval(offsets.sent))

        try await scheduling.schedule(sent)

        #expect(await scheduling.pendingRequests().isEmpty)
        if fake == .scripted {
            let scripted = try #require(scheduling as? ScriptedNotifications)
            // The expected instant is a literal whole second from `now`, so it
            // doesn't depend on the fake or on the adapter's truncation.
            let expected = Self.request(fireDate: now.addingTimeInterval(offsets.wholeSecond))
            #expect(await scripted.delivered == [expected])
        }
    }

    /// The other side of the boundary above: 1 s ahead of a whole-second `now`
    /// names a later second, so the request stays pending and nothing is
    /// delivered. The adapter-level pair is `triggerInstantNotAfterNowDeliversImmediately`
    /// and `triggerInstantOneSecondAfterNowGetsCalendarTrigger` in
    /// `UserNotificationsAdapterRequestTests`.
    @Test("A request exactly 1 second ahead is pending and not delivered", arguments: Fake.allCases)
    func requestOneSecondAheadIsPending(_ fake: Fake) async throws {
        let now = Self.now
        let scheduling = fake.make(clock: { now })
        let sent = Self.request(fireDate: now.addingTimeInterval(1))

        try await scheduling.schedule(sent)

        #expect(await scheduling.pendingRequests() == [sent])
        if fake == .scripted {
            let scripted = try #require(scheduling as? ScriptedNotifications)
            #expect(await scripted.delivered.isEmpty)
        }
    }

    /// The scripted fake reads a delivered request's whole second back from the
    /// adapter. With a fixed `now` of `.distantPast` for that read, a request
    /// dated `.distantPast` had no trigger to read and the fake ended the whole
    /// test process.
    @Test("A request dated .distantPast is delivered at once at its own whole second")
    func requestAtDistantPastIsDelivered() async throws {
        let scripted = ScriptedNotifications(clock: { Self.now })
        let sent = Self.request(fireDate: .distantPast)

        try await scripted.schedule(sent)

        #expect(await scripted.pendingRequests().isEmpty)
        #expect(await scripted.delivered == [sent])
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

    // MARK: - Delivery once time passes

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

    @Test("A request just before its time is still pending", arguments: Fake.allCases)
    func requestJustBeforeItsTimeIsStillPending(_ fake: Fake) async throws {
        let clock = MutableClock(Self.now)
        let scheduling = fake.make(clock: { clock.now() })
        let sent = Self.request(fireDate: Self.now.addingTimeInterval(60))
        try await scheduling.schedule(sent)

        clock.advance(by: 59.9)

        #expect(await scheduling.pendingRequests() == [sent])
    }

    @Test("A due request is delivered before a cancel of its id, with no read in between")
    func dueRequestIsDeliveredBeforeACancel() async throws {
        let clock = MutableClock(Self.now)
        let scripted = ScriptedNotifications(clock: { clock.now() })
        let sent = Self.request(fireDate: Self.now.addingTimeInterval(60))
        try await scripted.schedule(sent)

        clock.advance(by: 60)
        await scripted.cancel(identifiers: [sent.identifier])

        #expect(await scripted.delivered == [sent])
        #expect(await scripted.pendingRequests().isEmpty)
    }

    @Test("A due request is delivered before a same-id schedule, with no read in between")
    func dueRequestIsDeliveredBeforeASameIdSchedule() async throws {
        let clock = MutableClock(Self.now)
        let scripted = ScriptedNotifications(clock: { clock.now() })
        let first = Self.request(body: "first", fireDate: Self.now.addingTimeInterval(60))
        let second = Self.request(body: "second", fireDate: Self.now.addingTimeInterval(60 + 3600))
        try await scripted.schedule(first)

        clock.advance(by: 60)
        try await scripted.schedule(second)

        #expect(await scripted.delivered == [first])
        #expect(await scripted.pendingRequests() == [second])
    }

    @Test("Requests that come due together are delivered in fire-date order")
    func dueRequestsAreDeliveredInFireDateOrder() async throws {
        let clock = MutableClock(Self.now)
        let scripted = ScriptedNotifications(clock: { clock.now() })
        let earlier = Self.request(id: "b", fireDate: Self.now.addingTimeInterval(30))
        let later = Self.request(id: "a", fireDate: Self.now.addingTimeInterval(60))
        try await scripted.schedule(later)
        try await scripted.schedule(earlier)

        clock.advance(by: 60)

        #expect(await scripted.pendingRequests().isEmpty)
        #expect(await scripted.delivered == [earlier, later])
    }

    // MARK: - Cancel and replace

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

    // MARK: - The mock launch's fake

    /// The mock launch builds its `DebugNotificationScheduling` on the runtime's
    /// frozen clock (`MockRepositories.defaultNow`). On the real clock, a
    /// request 60 s after that instant would read as already due and never be
    /// pending.
    ///
    /// This test lives here because `NotificationCallerGateTests` allows
    /// `.schedule(` and `.pendingRequests(` calls only in this file and the
    /// adapter folder. Slice 4 deletes that gate.
    @Test("The mock launch's fake lists a request scheduled for 60 s after the runtime's frozen now")
    @MainActor
    func mockLaunchFakeUsesTheFrozenClock() async throws {
        let launch = AppLaunchCoordinator.mockRuntimeLaunch(environment: [:])
        let scheduling = try #require(launch.notifications)
        let sent = Self.request(fireDate: MockRepositories.defaultNow.addingTimeInterval(60))

        try await scheduling.schedule(sent)

        #expect(await scheduling.pendingRequests() == [sent])
    }
}
