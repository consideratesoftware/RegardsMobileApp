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
        // Synchronous body. `enumerateContacts` blocks while it streams
        // results, but `CNContactStore` is documented thread-safe, so the
        // cooperative thread the runtime hands us is fine. We avoid
        // `Task.detached` because `CNContactStore` and `CNContactFetchRequest`
        // aren't `Sendable` and capturing them into a Sendable closure
        // doesn't compile under Swift 6 strict concurrency.
        let keys: [any CNKeyDescriptor] = [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
        ].map { $0 as any CNKeyDescriptor }
        let request = CNContactFetchRequest(keysToFetch: keys)
        var results: [SystemContact] = []
        try store.enumerateContacts(with: request) { cn, _ in
            results.append(SystemContact(
                identifier: cn.identifier,
                givenName: cn.givenName,
                familyName: cn.familyName,
                phoneNumbers: cn.phoneNumbers.map { $0.value.stringValue },
                emailAddresses: cn.emailAddresses.map { $0.value as String }))
        }
        return results
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
