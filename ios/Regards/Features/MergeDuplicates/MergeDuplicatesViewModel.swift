import Foundation
import Observation

public struct DuplicateCandidateState: Sendable, Identifiable, Equatable {
    public struct Member: Sendable, Equatable {
        public let contactId: UUID
        public let displayName: String
        public let phone: String?
        public let email: String?
    }

    public var id: String {
        "\(a.contactId.uuidString)|\(b.contactId.uuidString)"
    }
    public let a: Member
    public let b: Member
    public let confidence: DuplicateCandidate.Confidence
    public let rationale: String
    public var primaryIsA: Bool
    public var isSelected: Bool
}

@Observable @MainActor
public final class MergeDuplicatesViewModel {

    public private(set) var candidates: [DuplicateCandidateState] = []
    private(set) var loadState: RegardsLoadState = .loading

    private let contacts: any ContactRepository
    private let detector = DuplicateDetector()
    private var hasLoaded = false

    public init(contacts: any ContactRepository) {
        self.contacts = contacts
    }

    public func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        loadState = .loading

        let all: [Contact]
        do {
            all = try await contacts.fetchAll()
        } catch {
            hasLoaded = false
            Self.log.error("failed to fetch contacts for duplicate detection: \(error, privacy: .public)")
            candidates = []
            loadState = .failed
            return
        }
        let inputs = all.map { contact in
            let value = contact.preferredChannelValue
            let isPhone = !value.isEmpty
                && ChannelCatalog.isPhoneE164(ChannelCatalog.normalizedPhone(value))
            let isEmail = ChannelCatalog.isEmail(value)
            return DuplicateDetector.Input(
                contactId: contact.id,
                displayName: contact.displayName,
                phones: isPhone ? [value] : [],
                emails: isEmail ? [value] : []
            )
        }
        let pairs = detector.candidates(from: inputs)
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        candidates = pairs.compactMap { pair -> DuplicateCandidateState? in
            guard let contactA = byId[pair.contactA], let contactB = byId[pair.contactB] else { return nil }
            return DuplicateCandidateState(
                a: Self.member(from: contactA),
                b: Self.member(from: contactB),
                confidence: pair.confidence,
                rationale: pair.rationale,
                primaryIsA: true,
                isSelected: pair.confidence == .high
            )
        }
        loadState = .loaded
    }

    public func toggleSelection(for id: String) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[idx].isSelected.toggle()
    }

    public func setPrimary(for id: String, isA: Bool) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[idx].primaryIsA = isA
    }

    static let log = RegardsLogger.feature("MergeDuplicates")

    static func member(from contact: Contact) -> DuplicateCandidateState.Member {
        var phone: String?
        var email: String?
        let value = contact.preferredChannelValue
        if !value.isEmpty {
            if ChannelCatalog.isEmail(value) { email = value }
            else { phone = value }
        }
        return DuplicateCandidateState.Member(
            contactId: contact.id,
            displayName: contact.displayName,
            phone: phone,
            email: email
        )
    }
}
