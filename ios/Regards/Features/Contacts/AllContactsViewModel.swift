import Foundation
import Observation

@Observable @MainActor
final class AllContactsViewModel {
    private(set) var contacts: [Contact] = []
    private(set) var now: Date = .distantPast
    private(set) var loadState: RegardsLoadState = .loading

    private let repository: any ContactRepository
    private let clock: () -> Date
    private var loadGeneration = 0

    init(contacts: any ContactRepository,
         clock: @escaping () -> Date = { Date() }) {
        self.repository = contacts
        self.clock = clock
    }

    var summary: String {
        switch loadState {
        case .loading: "Loading…"
        case .failed: "Unavailable"
        case .loaded:
            contacts.count == 1 ? "1 contact" : "\(contacts.count) contacts"
        }
    }

    func filtered(searchText: String) -> [Contact] {
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
            var loadedContacts = try await repository.fetchAll().filter(\.isActive)
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
            loadState = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            Self.log.error("failed to load contacts: \(error, privacy: .public)")
            now = loadedAt
            contacts = []
            loadState = .failed
        }
    }

    private static let log = RegardsLogger.feature("AllContacts")
}
