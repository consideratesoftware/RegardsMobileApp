import Foundation
@testable import Regards

/// One scripted outcome of `requestAuthorization()`: it succeeds or throws,
/// and may record the user's decision first (a prompt answered and then
/// erroring).
enum ScriptedRequestStep: Sendable {
    case succeeds(deciding: NotificationAuthorizationStatus?)
    case fails(deciding: NotificationAuthorizationStatus?)
}

/// One scripted `NotificationScheduling` for the cases `DebugNotificationScheduling`
/// can't express, because it has a single fixed request outcome and answers
/// every status read at once. It holds:
/// - request steps, consumed one per call: succeed or throw, and optionally
///   record the user's decision first (a prompt answered and then erroring);
///   once they run out a request grants;
/// - held status reads: after `immediateReads` reads, the next `heldReads`
///   suspend until the test releases each one with the value it should return,
///   in any order, so a stale read can finish last;
/// - the pending set, keyed by identifier like the system's, with a record of
///   every `schedule` and `cancel` call (`scheduleCalls`, `cancelCalls`);
/// - `delivered`, the requests the fake treats as delivered: fake-only
///   bookkeeping for tests;
/// - `UnreadableRequest`, which `schedule` throws when the adapter can't read
///   back the request it just built.
actor ScriptedNotifications: NotificationScheduling {
    // MARK: - State

    private var status: NotificationAuthorizationStatus
    private var steps: [ScriptedRequestStep]
    private(set) var requestCount = 0
    private var immediateReads: Int
    private var holdsRemaining: Int
    private var heldReads: [CheckedContinuation<NotificationAuthorizationStatus, Never>] = []
    private var pending: [String: ReminderNotificationRequest] = [:]
    private(set) var scheduleCalls: [ReminderNotificationRequest] = []
    private(set) var cancelCalls: [[String]] = []
    /// Fake-only bookkeeping for tests. The real center exposes no fire date
    /// for a delivered notification, so nothing here is a device contract.
    /// These are the requests the fake treats as delivered, at once on add or
    /// once their time passes (checked at the start of every call to any of
    /// the 3 live members), each with its whole-second fire date. Due requests
    /// are recorded in fire-date order, with identifier as a tiebreak. This
    /// order is the fake's own deterministic choice. Slice 4 tests must not
    /// rely on the real center's order for requests that come due together.
    private(set) var delivered: [ReminderNotificationRequest] = []
    private let clock: @Sendable () -> Date

    /// Thrown by `schedule` when the adapter can't read back the request it
    /// just built. It means the adapter is broken, and it fails the one test
    /// that scheduled the request instead of ending the whole test process.
    struct UnreadableRequest: Error {
        let identifier: String
    }

    init(
        status: NotificationAuthorizationStatus = .notDetermined,
        requests: [ScriptedRequestStep] = [],
        immediateReads: Int = .max,
        heldReads: Int = 0,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clock = clock
        self.status = status
        self.steps = requests
        self.immediateReads = immediateReads
        self.holdsRemaining = heldReads
    }

    // MARK: - Authorization

    nonisolated var actions: AsyncStream<NotificationAction> {
        AsyncStream { $0.finish() }
    }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        switch steps.isEmpty ? .succeeds(deciding: .authorized) : steps.removeFirst() {
        case .succeeds(let decision):
            if let decision { status = decision }
            return decision == .authorized
        case .fails(let decision):
            if let decision { status = decision }
            throw DebugNotificationScheduling.RequestFailed()
        }
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        if immediateReads > 0 {
            immediateReads -= 1
            return status
        }
        guard holdsRemaining > 0 else { return status }
        holdsRemaining -= 1
        return await withCheckedContinuation { heldReads.append($0) }
    }

    /// The system's real status from now on (what an unheld read returns).
    func setStatus(_ newStatus: NotificationAuthorizationStatus) {
        status = newStatus
    }

    // MARK: - Scheduling

    /// Scheduling members: a pending set keyed by identifier like the
    /// system's (`schedule` replaces, `cancel` removes), plus a record of every
    /// call in order. `schedule` stores each request through the adapter's own
    /// `makeRequest` and `decode`, so a fire date comes back truncated to the
    /// whole second, and a request whose trigger instant is not after the clock
    /// is delivered at once: it is recorded in `delivered`, replaces any
    /// pending request with its identifier, and is never pending. The set has
    /// no size limit, unlike the system's 64 pending requests per app; see
    /// `NotificationFakeParityTests`. `pendingRequests()` sorts by identifier
    /// only to keep tests deterministic. The real center's order is
    /// unspecified, so a test must not rely on this one.
    ///
    /// A pending request whose time passes is delivered at the next call of any
    /// of the 3 members (`deliverDue`), before that call acts, so a cancel or a
    /// same-id schedule can't hide it. `delivered` always holds the whole-second
    /// fire date.
    func pendingRequests() async -> [ReminderNotificationRequest] {
        deliverDue()
        return pending.values.sorted { $0.identifier < $1.identifier }
    }

    func schedule(_ request: ReminderNotificationRequest) async throws {
        deliverDue()
        scheduleCalls.append(request)
        let built = UserNotificationsAdapter.makeRequest(request, now: clock())
        if let stored = UserNotificationsAdapter.decode(built) {
            pending[request.identifier] = stored
        } else {
            // The delivered fire date is the adapter's own whole second, read back
            // from a request built with a `now` 2 s before the fire date. The whole
            // second is never more than 1 s before the fire date, so the request
            // keeps a trigger whatever the fire date is.
            guard let wholeSecond = UserNotificationsAdapter.decode(
                UserNotificationsAdapter.makeRequest(request, now: request.fireDate.addingTimeInterval(-2))
            ) else {
                throw UnreadableRequest(identifier: request.identifier)
            }
            pending[request.identifier] = nil
            delivered.append(ReminderNotificationRequest(
                identifier: request.identifier,
                title: request.title,
                body: request.body,
                fireDate: wholeSecond.fireDate,
                kind: request.kind
            ))
        }
    }

    func cancel(identifiers: [String]) async {
        deliverDue()
        cancelCalls.append(identifiers)
        for identifier in identifiers {
            pending[identifier] = nil
        }
    }

    /// Moves every pending request whose time is at or before the clock to
    /// `delivered`, in fire-date order, then identifier order.
    private func deliverDue() {
        let now = clock()
        let due = pending.values.filter { $0.fireDate <= now }
            .sorted { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }
        for request in due {
            pending[request.identifier] = nil
            delivered.append(request)
        }
    }

    // MARK: - Held status reads

    var heldReadCount: Int { heldReads.count }

    /// Lets the held read at `index` (in call order) return `value`.
    func release(read index: Int, as value: NotificationAuthorizationStatus) {
        heldReads[index].resume(returning: value)
    }
}
