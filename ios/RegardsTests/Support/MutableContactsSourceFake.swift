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
    private var continuation: AsyncStream<Void>.Continuation?

    init(status: ContactsAuthorizationStatus, contacts: [SystemContact] = []) {
        self.status = status
        self.contacts = contacts
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus {
        lock.withLock { status }
    }

    func requestAccess() async throws -> ContactsAuthorizationStatus {
        lock.withLock { status }
    }

    func fetchAllContacts() async throws -> [SystemContact] {
        lock.withLock {
            fetchCount += 1
            return contacts
        }
    }

    func setStatus(_ newStatus: ContactsAuthorizationStatus) {
        lock.withLock { status = newStatus }
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
