import Foundation
@testable import Regards

/// A `ContactsSource` whose authorization status and visible contact list
/// can change between calls — for scenarios a fixed fixture can't model,
/// like an `.authorized → .limited` downgrade between two `reconcile()`
/// passes, or a `CNContactStoreDidChange` notification a test wants to
/// drive explicitly. A plain fixed-fixture use (never calling `setStatus`/
/// `setContacts`/`simulateChange`) works too, so this doubles as the
/// general-purpose `ContactsSource` fake across the reconciliation suites.
final class MutableContactsSource: ContactsSource, @unchecked Sendable {
    private let lock = NSLock()
    private var status: ContactsAuthorizationStatus
    private var contacts: [SystemContact]
    private var fetchCount = 0
    private var requestCount = 0
    /// What the next `requestAccess()` does. Nil keeps the old behavior:
    /// return the current status without changing it.
    private var requestOutcome: Result<ContactsAuthorizationStatus, any Error>?
    /// With a failure outcome: the status the system records before the
    /// request throws. On a device a decline arrives this way (CNError 100
    /// while the status becomes `.denied`).
    private var statusDecidedOnFailure: ContactsAuthorizationStatus?
    /// Status reads let through before the held ones, and how many of the next
    /// reads then suspend until a test releases each with the value it returns.
    private var immediateReads = Int.max
    private var holdsRemaining = 0
    private var heldReads: [CheckedContinuation<ContactsAuthorizationStatus, Never>] = []
    private var continuation: AsyncStream<Void>.Continuation?
    /// Fires once per `fetchAllContacts()` call, right before it returns —
    /// lets a test simulate a permission change landing mid-enumeration
    /// (e.g. a TOCTOU downgrade) without needing a real blocking mechanism.
    private var onFetchAllContacts: (@Sendable () -> Void)?

    init(status: ContactsAuthorizationStatus, contacts: [SystemContact] = []) {
        self.status = status
        self.contacts = contacts
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus {
        let shouldHold: Bool = lock.withLock {
            if immediateReads > 0 {
                immediateReads -= 1
                return false
            }
            guard holdsRemaining > 0 else { return false }
            holdsRemaining -= 1
            return true
        }
        guard shouldHold else { return lock.withLock { status } }
        return await withCheckedContinuation { continuation in
            lock.withLock { heldReads.append(continuation) }
        }
    }

    /// After `immediateReads` more reads, the next `count` status reads
    /// suspend until `releaseHeldRead(at:as:)`, so an older read can finish
    /// after a newer one.
    func holdReads(after immediateReads: Int = 0, count: Int) {
        lock.withLock {
            self.immediateReads = immediateReads
            holdsRemaining = count
        }
    }

    func heldReadCountValue() -> Int {
        lock.withLock { heldReads.count }
    }

    /// Lets the held read at `index` (in call order) return `value`.
    func releaseHeldRead(at index: Int, as value: ContactsAuthorizationStatus) {
        lock.withLock { heldReads[index] }.resume(returning: value)
    }

    func requestAccess() async throws -> ContactsAuthorizationStatus {
        let outcome: Result<ContactsAuthorizationStatus, any Error>? = lock.withLock {
            requestCount += 1
            switch requestOutcome {
            case .success(let granted)?: status = granted
            case .failure?: if let decided = statusDecidedOnFailure { status = decided }
            case nil: break
            }
            return requestOutcome
        }
        switch outcome {
        case .success(let granted)?: return granted
        case .failure(let error)?: throw error
        case nil: return lock.withLock { status }
        }
    }

    /// Scripts the system prompt: a success becomes the new status, a failure
    /// throws and leaves the status alone unless `decidingOnFailure` says the
    /// user's decision was recorded first.
    func setRequestOutcome(
        _ outcome: Result<ContactsAuthorizationStatus, any Error>?,
        decidingOnFailure decided: ContactsAuthorizationStatus? = nil
    ) {
        lock.withLock {
            requestOutcome = outcome
            statusDecidedOnFailure = decided
        }
    }

    func requestCountValue() -> Int {
        lock.withLock { requestCount }
    }

    func fetchAllContacts() async throws -> [SystemContact] {
        let hook = lock.withLock { onFetchAllContacts }
        hook?()
        return lock.withLock {
            fetchCount += 1
            return contacts
        }
    }

    func setStatus(_ newStatus: ContactsAuthorizationStatus) {
        lock.withLock { status = newStatus }
    }

    /// Set to `nil` to clear. Runs synchronously inside `fetchAllContacts()`,
    /// just before it returns, so a test can flip status/contacts partway
    /// through what looks like one enumeration.
    func setFetchAllContactsHook(_ hook: (@Sendable () -> Void)?) {
        lock.withLock { onFetchAllContacts = hook }
    }

    func setContacts(_ newContacts: [SystemContact]) {
        lock.withLock { contacts = newContacts }
    }

    func fetchCountValue() -> Int {
        lock.withLock { fetchCount }
    }

    func changeNotifications() -> AsyncStream<Void> {
        // Adopts the exact same buffering policy `CNContactsSource` uses in
        // production, so a burst-coalescing test against this fake proves
        // real behavior instead of a policy the fake invented on its own.
        AsyncStream(bufferingPolicy: changeNotificationBufferingPolicy) { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func simulateChange() {
        lock.withLock { continuation }?.yield()
    }
}
