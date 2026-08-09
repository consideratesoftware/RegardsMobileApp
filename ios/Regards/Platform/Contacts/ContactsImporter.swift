import Foundation

/// Orchestrates a one-shot first-launch import: read every contact the user
/// authorized us to see, map each into our `Contact` domain type, and insert
/// new rows into the `ContactRepository`. Existing rows (matched by
/// `systemContactRef`) are left alone — this importer is additive, not a
/// reconciler. Delete-detection and change-detection arrive in a follow-up
/// (ARCHITECTURE.md §7 "Re-import logic").
///
/// All imported contacts land as `tracked: false`. The user opts each contact
/// in from the All Contacts screen.
public struct ContactsImporter: Sendable {
    private let source: any ContactsSource
    private let repo: any ContactRepository
    private let clock: @Sendable () -> Date

    public init(
        source: any ContactsSource,
        repo: any ContactRepository,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.repo = repo
        self.clock = clock
    }

    /// Outcome of an import pass. `imported` is rows freshly written;
    /// `skipped` is rows the importer found already in the DB and left alone.
    public struct Result: Sendable, Equatable {
        public let imported: Int
        public let skipped: Int
    }

    /// Errors the importer surfaces to the caller.
    public enum ImportError: Error, Equatable {
        /// Caller invoked the importer without an authorized status.
        case notAuthorized(ContactsAuthorizationStatus)
    }

    /// Reads everything from the system store and inserts new rows.
    /// Throws `ImportError.notAuthorized` if the source's current status
    /// isn't `.authorized` or `.limited`. Each row commits independently;
    /// rerunning after an interruption skips rows already written and resumes
    /// with the remaining system contacts.
    public func runFirstLaunchImport() async throws -> Result {
        let status = await source.currentAuthorization()
        guard status == .authorized || status == .limited else {
            throw ImportError.notAuthorized(status)
        }

        let systemContacts = try await source.fetchAllContacts()
        let existing = try await repo.fetchAll()
        var existingRefs = Set(existing.map(\.systemContactRef))

        var imported = 0
        var skipped = 0
        let now = clock()
        for sc in systemContacts {
            if existingRefs.contains(sc.identifier) {
                skipped += 1
                continue
            }
            try await repo.upsert(Self.map(systemContact: sc, now: now))
            existingRefs.insert(sc.identifier)
            imported += 1
        }
        return Result(imported: imported, skipped: skipped)
    }

    /// Pure mapping function. Exposed for unit tests so each translation
    /// rule can be checked without going through the importer's I/O.
    ///
    /// Mapping rules:
    /// - `displayName`: "Given Family", trimmed empties out. Falls back to
    ///   the first phone number, then the first email, then "Unknown".
    /// - `preferredChannel` + `preferredChannelValue`: first valid phone
    ///   number under `.phoneCall`. If none, first valid email under `.email`.
    ///   Values that cannot produce a valid deep link are retained in the
    ///   contact-value arrays but leave the preferred value empty for later
    ///   user correction.
    /// - Every E.164-parseable phone is normalized before persistence. Raw
    ///   values are retained when the country code cannot be resolved from
    ///   the source value. Every email is lowercased.
    public static func map(systemContact sc: SystemContact, now: Date) -> Contact {
        let resolvedDisplayName: String
        if !sc.displayName.isEmpty {
            resolvedDisplayName = sc.displayName
        } else if let phone = sc.phoneNumbers.first {
            resolvedDisplayName = phone
        } else if let email = sc.emailAddresses.first {
            resolvedDisplayName = email
        } else {
            resolvedDisplayName = "Unknown"
        }

        let phoneNumbers = sc.phoneNumbers.map { rawValue in
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ChannelCatalog.isPhoneE164(trimmed) else { return rawValue }
            return ChannelCatalog.normalizedPhone(trimmed)
        }
        let emailAddresses = sc.emailAddresses.map { $0.lowercased() }
        let primaryPhone = phoneNumbers.first(where: ChannelCatalog.isPhoneE164) ?? ""
        let primaryEmail = emailAddresses.first {
            ChannelCatalog.validate(value: $0, for: .email)
        } ?? ""
        let preferredChannel: Channel
        let preferredChannelValue: String
        if !primaryPhone.isEmpty {
            preferredChannel = .phoneCall
            preferredChannelValue = primaryPhone
        } else if !primaryEmail.isEmpty {
            preferredChannel = .email
            preferredChannelValue = primaryEmail
        } else if !emailAddresses.isEmpty && phoneNumbers.isEmpty {
            preferredChannel = .email
            preferredChannelValue = ""
        } else {
            preferredChannel = .phoneCall
            preferredChannelValue = ""
        }

        return Contact(
            systemContactRef: sc.identifier,
            displayName: resolvedDisplayName,
            tracked: false,
            preferredChannel: preferredChannel,
            preferredChannelValue: preferredChannelValue,
            phoneNumbers: phoneNumbers,
            emailAddresses: emailAddresses,
            createdAt: now)
    }

}
