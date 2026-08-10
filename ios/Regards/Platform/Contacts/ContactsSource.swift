import Foundation
import Contacts

/// Permission state mirrored from `CNAuthorizationStatus`. We don't pass
/// `CNAuthorizationStatus` itself outside the Platform layer so the Domain
/// layer never has to import Contacts.framework.
public enum ContactsAuthorizationStatus: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
    /// iOS 18+. Treat as `authorized` for our purposes; the system already
    /// scoped the visible contacts to whatever the user picked.
    case limited
}

/// Platform-neutral snapshot of a `CNContact`'s fields. We cherry-pick only
/// what the importer needs so Domain code can reason about a contact without
/// depending on Contacts.framework types.
public struct SystemContact: Sendable, Equatable {
    public let identifier: String
    public let givenName: String
    public let familyName: String
    public let phoneNumbers: [String]
    public let emailAddresses: [String]
    public let birthday: DateComponents?

    public init(
        identifier: String,
        givenName: String,
        familyName: String,
        phoneNumbers: [String],
        emailAddresses: [String],
        birthday: DateComponents? = nil
    ) {
        self.identifier = identifier
        self.givenName = givenName
        self.familyName = familyName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.birthday = birthday
    }

    public var displayName: String {
        let parts = [givenName, familyName].filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }
}

/// Read-only seam over the system Contacts store. Production wires this to
/// `CNContactsSource`; unit tests inject a `FakeContactsSource` so they don't
/// depend on the simulator's Contacts DB shape or trigger a real permission
/// prompt.
public protocol ContactsSource: Sendable {
    func currentAuthorization() async -> ContactsAuthorizationStatus
    /// Triggers the system permission sheet on first call. Subsequent calls
    /// return immediately with the cached decision.
    func requestAccess() async throws -> ContactsAuthorizationStatus
    /// Enumerates every contact the app is currently authorized to see. On
    /// `.limited` access (iOS 18+) the system already filtered the result.
    func fetchAllContacts() async throws -> [SystemContact]
    /// Fires once per `CNContactStoreDidChange` notification — a contact
    /// added, edited, or deleted in Contacts.app or synced from iCloud — so
    /// `ContactsReconciler` can re-run without polling (ARCHITECTURE.md §7,
    /// PR21). The default below never emits, so fakes that don't model live
    /// changes keep compiling unchanged.
    func changeNotifications() -> AsyncStream<Void>
}

public extension ContactsSource {
    func changeNotifications() -> AsyncStream<Void> {
        AsyncStream { continuation in continuation.finish() }
    }
}

/// Wraps a non-`Sendable` value so it can cross into a `@Sendable` closure.
/// Used only to hand `CNContactStore`/`CNContactFetchRequest` (undocumented
/// as `Sendable` but documented thread-safe — see `CNContactsSource` below)
/// to a background dispatch queue; the box is never read concurrently from
/// two places at once.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Runs a blocking, non-`Sendable`-capturing closure on a GCD global queue
/// instead of the Swift concurrency cooperative thread pool. `CNContactStore
/// .enumerateContacts` streams results synchronously and can take long enough
/// on a large address book (§19 R25 — measured stalling a cooperative-pool
/// worker at ~5k contacts) to starve every other async task sharing that
/// pool. Dispatching the blocking work elsewhere keeps the pool free.
func runOffCooperativePool<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        DispatchQueue.global(qos: qos).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Default `ContactsSource` backed by a real `CNContactStore`.
///
/// `@unchecked Sendable` because `CNContactStore` itself is documented
/// thread-safe ("All `CNContactStore` instances may be used on any thread.")
/// but Apple hasn't annotated it as `Sendable`.
public struct CNContactsSource: ContactsSource, @unchecked Sendable {
    private let store: CNContactStore

    public init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    public func currentAuthorization() async -> ContactsAuthorizationStatus {
        Self.translate(CNContactStore.authorizationStatus(for: .contacts))
    }

    public func requestAccess() async throws -> ContactsAuthorizationStatus {
        // Bridge the callback API to async. The iOS 18+ async overload would
        // simplify this, but we target iOS 17.
        _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: granted)
                }
            }
        }
        // After the prompt resolves, re-read the canonical status. The
        // `granted` boolean from the callback collapses `.authorized` and
        // `.limited` into `true`, which loses information we want.
        return Self.translate(CNContactStore.authorizationStatus(for: .contacts))
    }

    public func fetchAllContacts() async throws -> [SystemContact] {
        // `enumerateContacts` blocks synchronously while it streams results.
        // `CNContactStore` is documented thread-safe ("All CNContactStore
        // instances may be used on any thread."), so running it on a GCD
        // worker via `runOffCooperativePool` — instead of the calling
        // cooperative-pool thread — is safe and is the R25 fix: a large
        // address book no longer stalls other async work sharing the pool.
        let keys: [any CNKeyDescriptor] = [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
        ].map { $0 as any CNKeyDescriptor }
        let request = CNContactFetchRequest(keysToFetch: keys)
        let box = UncheckedSendableBox((store: store, request: request))
        return try await runOffCooperativePool {
            var results: [SystemContact] = []
            try box.value.store.enumerateContacts(with: box.value.request) { cn, _ in
                results.append(SystemContact(
                    identifier: cn.identifier,
                    givenName: cn.givenName,
                    familyName: cn.familyName,
                    phoneNumbers: cn.phoneNumbers.map { $0.value.stringValue },
                    emailAddresses: cn.emailAddresses.map { $0.value as String }))
            }
            return results
        }
    }

    /// `@unchecked Sendable` because the `NSObjectProtocol` observer token
    /// isn't `Sendable`, but the box only ever hands it between `start` and
    /// `stop`, never touched from two places at once.
    private final class NotificationObserverBox: @unchecked Sendable {
        private var token: (any NSObjectProtocol)?
        private let center = NotificationCenter.default

        func start(name: Notification.Name, onFire: @escaping @Sendable () -> Void) {
            token = center.addObserver(forName: name, object: nil, queue: nil) { _ in onFire() }
        }

        func stop() {
            if let token { center.removeObserver(token) }
            token = nil
        }
    }

    public func changeNotifications() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let box = NotificationObserverBox()
            box.start(name: .CNContactStoreDidChange) {
                continuation.yield()
            }
            continuation.onTermination = { _ in
                box.stop()
            }
        }
    }

    private static func translate(_ status: CNAuthorizationStatus) -> ContactsAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        case .denied:        return .denied
        case .authorized:    return .authorized
        case .limited:       return .limited
        @unknown default:    return .denied
        }
    }
}
