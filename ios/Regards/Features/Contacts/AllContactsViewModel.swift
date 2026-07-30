import Foundation
import Observation

@Observable @MainActor
final class AllContactsViewModel {
    private(set) var contacts: [Contact] = []
    private(set) var now: Date = .distantPast
    private(set) var loadState: RegardsLoadState = .loading

    private let repository: any ContactRepository
    private let clock: () -> Date

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
        loadState = .loading
        now = clock()
        do {
            contacts = try await repository.fetchTracked()
            contacts.sort { $0.priorityTier.rawValue < $1.priorityTier.rawValue }
            loadState = .loaded
        } catch {
            Self.log.error("failed to load tracked contacts: \(error, privacy: .public)")
            contacts = []
            loadState = .failed
        }
    }

    private static let log = RegardsLogger.feature("AllContacts")
}
