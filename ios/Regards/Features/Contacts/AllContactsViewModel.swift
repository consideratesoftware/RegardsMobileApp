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
        case .loaded: "\(contacts.count) tracked"
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
            var loadedContacts = try await repository.fetchTracked()
            loadedContacts.sort { $0.priorityTier.rawValue < $1.priorityTier.rawValue }
            guard generation == loadGeneration else { return }
            now = loadedAt
            contacts = loadedContacts
            loadState = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            Self.log.error("failed to load tracked contacts: \(error, privacy: .public)")
            now = loadedAt
            contacts = []
            loadState = .failed
        }
    }

    private static let log = RegardsLogger.feature("AllContacts")
}
