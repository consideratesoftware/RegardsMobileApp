import Foundation

/// Orchestrates a one-shot first-launch import: read every contact the user
/// authorized us to see, map each into our `Contact` domain type, and insert
/// new rows into the `ContactRepository`. Existing rows (matched by
/// `systemContactRef`) are left alone — this importer is additive, not a
/// reconciler. Ongoing delete-detection, change-detection, and archive
/// safety live in `ContactsReconciler` (ARCHITECTURE.md §7 "Re-import &
/// reconciliation", PR21), which reuses `map(systemContact:now:)` below.
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
    /// `skipped` is rows the importer found already in the DB and left
    /// alone; `failed` is rows whose write failed and were neither (R35 —
    /// counted and logged, never silently dropped).
    public struct Result: Sendable, Equatable {
        public let imported: Int
        public let skipped: Int
        public let failed: Int

        public init(imported: Int, skipped: Int, failed: Int = 0) {
            self.imported = imported
            self.skipped = skipped
            self.failed = failed
        }
    }

    /// Errors the importer surfaces to the caller.
    public enum ImportError: Error, Equatable {
        /// Caller invoked the importer without an authorized status.
        case notAuthorized(ContactsAuthorizationStatus)
    }

    /// Reads everything from the system store and inserts new rows.
    /// Throws `ImportError.notAuthorized` if the source's current status
    /// isn't `.authorized` or `.limited`. Each row commits independently: a
    /// single row's write failure is logged and counted in `failed` rather
    /// than aborting the pass (R35), so the rest of a large address book
    /// still imports. A failed row never joins the resolved-identifier set,
    /// so rerunning retries it along with anything not yet attempted.
    public func runFirstLaunchImport() async throws -> Result {
        let status = await source.currentAuthorization()
        guard status == .authorized || status == .limited else {
            throw ImportError.notAuthorized(status)
        }

        let systemContacts = try await source.fetchAllContacts()
        // Corrupted existing rows still occupy their `systemContactRef` in
        // the unique-constrained column even though they can't decode to a
        // `Contact` — folding their refs in here keeps the importer from
        // attempting a doomed duplicate insert against a row R50 deliberately
        // preserves untouched.
        let report = try await repo.fetchAllWithDiagnostics()
        var existingRefs = Set(report.contacts.map(\.systemContactRef))
        existingRefs.formUnion(report.corrupted.map(\.systemContactRef))

        var imported = 0
        var skipped = 0
        var failed = 0
        let now = clock()
        for sc in systemContacts {
            if existingRefs.contains(sc.identifier) {
                skipped += 1
                continue
            }
            do {
                try await repo.upsert(Self.map(systemContact: sc, now: now))
                existingRefs.insert(sc.identifier)
                imported += 1
            } catch {
                failed += 1
                Self.log.error(
                    "import failed for \(sc.identifier, privacy: .private): \(error, privacy: .private)"
                )
            }
        }
        return Result(imported: imported, skipped: skipped, failed: failed)
    }

    private static let log = RegardsLogger.feature("ContactsImporter")

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
        let primaryPhone = ChannelCatalog.primaryPhone(in: phoneNumbers)
        let primaryEmail = ChannelCatalog.primaryEmail(in: emailAddresses)
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
