import Foundation
@testable import Regards

/// One scripted `NotificationScheduling` for the cases `DebugNotificationScheduling`
/// can't express, because it has a single fixed request outcome and answers
/// every status read at once:
/// - request steps, consumed one per call: succeed or throw, and optionally
///   record the user's decision first (a prompt answered and then erroring);
///   once they run out a request grants;
/// - held status reads: after `immediateReads` reads, the next `heldReads`
///   suspend until the test releases each one with the value it should return,
///   in any order, so a stale read can finish last.
enum ScriptedRequestStep: Sendable {
    case succeeds(deciding: NotificationAuthorizationStatus?)
    case fails(deciding: NotificationAuthorizationStatus?)
}

actor ScriptedNotifications: NotificationScheduling {
    private var status: NotificationAuthorizationStatus
    private var steps: [ScriptedRequestStep]
    private(set) var requestCount = 0
    private var immediateReads: Int
    private var holdableReads: Int
    private var heldReads: [CheckedContinuation<NotificationAuthorizationStatus, Never>] = []

    init(
        status: NotificationAuthorizationStatus = .notDetermined,
        requests: [ScriptedRequestStep] = [],
        immediateReads: Int = .max,
        heldReads: Int = 0
    ) {
        self.status = status
        self.steps = requests
        self.immediateReads = immediateReads
        self.holdableReads = heldReads
    }

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
        guard holdableReads > 0 else { return status }
        holdableReads -= 1
        return await withCheckedContinuation { heldReads.append($0) }
    }

    /// The system's real status from now on (what an unheld read returns).
    func setStatus(_ newStatus: NotificationAuthorizationStatus) {
        status = newStatus
    }

    var heldReadCount: Int { heldReads.count }

    /// Lets the held read at `index` (in call order) return `value`.
    func release(read index: Int, as value: NotificationAuthorizationStatus) {
        heldReads[index].resume(returning: value)
    }
}
