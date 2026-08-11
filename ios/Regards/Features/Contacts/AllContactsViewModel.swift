import Foundation
import Observation

@Observable @MainActor
final class AllContactsViewModel {
    private(set) var contacts: [Contact] = []
    private(set) var now: Date = .distantPast
    private(set) var loadState: RegardsLoadState = .loading
    /// Rows the repository could not decode this load (R50). Healthy
    /// contacts stay usable alongside this — the corrupt row is never
    /// dropped from the database, just excluded from `contacts`.
    private(set) var corruptedContactCount = 0

    private let repository: any ContactRepository
    private let clock: () -> Date
    @ObservationIgnored private let filterObserver: (@MainActor () -> Void)?
    private var loadGeneration = 0

    init(contacts: any ContactRepository,
         clock: @escaping () -> Date = { Date() },
         filterObserver: (@MainActor () -> Void)? = nil) {
        self.repository = contacts
        self.clock = clock
        self.filterObserver = filterObserver
    }

    var summary: String {
        switch loadState {
        case .loading: "Loading…"
        case .failed: "Unavailable"
        case .loaded:
            contacts.count == 1 ? "1 contact" : "\(contacts.count) contacts"
        }
    }

    /// `nil` when nothing is corrupted, so the screen only shows a banner
    /// when there's something to say.
    var corruptionMessage: String? {
        guard corruptedContactCount > 0 else { return nil }
        return corruptedContactCount == 1
            ? "1 contact couldn't be read and needs attention."
            : "\(corruptedContactCount) contacts couldn't be read and need attention."
    }

    func filtered(searchText: String) -> [Contact] {
        filterObserver?()
        guard !searchText.isEmpty else { return contacts }
        let query = searchText.lowercased()
        return contacts.filter {
            $0.displayName.lowercased().contains(query)
        }
    }

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if loadState != .loaded {
            loadState = .loading
        }
        let loadedAt = clock()
        do {
            let report = try await repository.fetchAllWithDiagnostics()
            for diagnostic in report.corrupted {
                Self.log.error("""
                    unreadable contact row \(diagnostic.rawId, privacy: .private): \
                    \(diagnostic.reason, privacy: .private)
                    """)
            }
            var loadedContacts = report.contacts.filter(\.isActive)
            loadedContacts.sort { lhs, rhs in
                if lhs.priorityTier != rhs.priorityTier {
                    return lhs.priorityTier.rawValue < rhs.priorityTier.rawValue
                }
                let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            guard generation == loadGeneration else { return }
            now = loadedAt
            contacts = loadedContacts
            corruptedContactCount = report.corrupted.count
            loadState = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            Self.log.error("failed to load contacts: \(error, privacy: .private)")
            now = loadedAt
            contacts = []
            corruptedContactCount = 0
            loadState = .failed
        }
    }

    private static let log = RegardsLogger.feature("AllContacts")
}
