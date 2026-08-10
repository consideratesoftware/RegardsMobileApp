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
        AsyncStream(bufferingPolicy: changeNotificationBufferingPolicy) { continuation in
            continuation.finish()
        }
    }
}

/// Coalesces a burst of rapid change notifications (e.g. several edits
/// applied in one sync batch) into a single pending signal instead of
/// queuing every one — a reconciliation pass already re-reads the *current*
/// state of the whole store, so replaying N stale wake-ups buys nothing.
/// Not `private`: `MutableContactsSource` (RegardsTests/Support) reuses this
/// exact policy so its burst-coalescing test proves the real production
/// value, not a duplicated literal that could silently drift from it.
let changeNotificationBufferingPolicy: AsyncStream<Void>.Continuation.BufferingPolicy = .bufferingNewest(1)

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
///
/// Cancellation is best-effort, checked once at entry (`Task.checkCancellation()`
/// below) and never again. Once `work` is dispatched to the GCD queue it
/// runs to completion; the calling task being cancelled after that point
/// doesn't stop `work` mid-flight, it just means the eventual
/// `continuation.resume` result feeds back into an already-cancelled
/// context. `CNContactStore.enumerateContacts`'s block-based API has no
/// cooperative-cancellation hook to check partway through anyway.
func runOffCooperativePool<T: Sendable>(
    qos: DispatchQoS.QoSClass = .userInitiated,
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
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
    /// R25 production-path seam (`ContactsSourceTests`, round 10): `nil` in
    /// every production/preview call site, so `fetchAllContacts()` below
    /// always performs the real `CNContactStore.enumerateContacts` call.
    /// Set only by the test-only initializer, so a test can drive this
    /// *actual* `fetchAllContacts()` method — including its real
    /// `runOffCooperativePool` call, in the same closure, at the same call
    /// site — with a synthetic enumeration instead of a real, populated
    /// Contacts database, which `CNContactStore` itself can't be faked to
    /// provide (Apple seals it).
    private let enumerateOverride: (@Sendable () throws -> [SystemContact])?

    public init(store: CNContactStore = CNContactStore()) {
        self.store = store
        self.enumerateOverride = nil
    }

    /// Test-only. Not `private`/`public`: `ContactsSourceTests` constructs
    /// this via `@testable import Regards`; nothing outside the module can
    /// see it.
    init(store: CNContactStore, enumerateOverride: @escaping @Sendable () throws -> [SystemContact]) {
        self.store = store
        self.enumerateOverride = enumerateOverride
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
        let enumerateOverride = self.enumerateOverride
        // The override check lives *inside* the closure `runOffCooperativePool`
        // wraps, not as a separate branch around a second call to it — one
        // call site, shared by production and the test seam, so a
        // regression that drops `runOffCooperativePool` here can't leave a
        // test-only path still exercising it while the real one doesn't.
        return try await runOffCooperativePool {
            if let enumerateOverride { return try enumerateOverride() }
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
    /// isn't `Sendable`. `queue: nil` in `start(name:onFire:)` below means
    /// `NotificationCenter` invokes the observer block synchronously on
    /// whichever thread posts the notification — not necessarily the thread
    /// that calls `stop()` (the `AsyncStream`'s `onTermination`, which can
    /// fire from anywhere) — so `token` genuinely can be read and written
    /// from two places at once; `lock` guards every access, matching
    /// `MutableContactsSource`'s (RegardsTests/Support) existing pattern for
    /// the same kind of test-fake state.
    private final class NotificationObserverBox: @unchecked Sendable {
        private let lock = NSLock()
        private var token: (any NSObjectProtocol)?
        private let center = NotificationCenter.default

        func start(name: Notification.Name, onFire: @escaping @Sendable () -> Void) {
            let newToken = center.addObserver(forName: name, object: nil, queue: nil) { _ in onFire() }
            lock.withLock { token = newToken }
        }

        func stop() {
            let existingToken = lock.withLock { () -> (any NSObjectProtocol)? in
                let existingToken = token
                token = nil
                return existingToken
            }
            if let existingToken { center.removeObserver(existingToken) }
        }
    }

    public func changeNotifications() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: changeNotificationBufferingPolicy) { continuation in
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
