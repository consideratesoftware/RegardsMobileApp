import Foundation
import Testing
@testable import Regards

/// Should-fix (TF-03 hosted review, round 7): `ContactsReconciler`'s refresh
/// writes must be field-scoped (`repo.updateReconciledFields`), not a
/// whole-row `upsert` built from a snapshot taken at the start of the pass.
/// Otherwise a concurrent write to a column reconciliation doesn't own —
/// e.g. `lastInteractedAt` from marking a contact caught up (TF-04) —
/// landing on the same row mid-pass would get silently reverted by the
/// reconciler's own write once it finally lands.
struct ContactsReconcilerFieldScopedWriteTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A concurrent lastInteractedAt write landing mid-pass survives the reconciler's refresh")
    func concurrentLastInteractedAtWriteSurvivesRefresh() async throws {
        let realRepo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let existing = Contact(
            systemContactRef: "concurrent-1",
            displayName: "Old Name",
            tracked: true,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+15555550910",
            phoneNumbers: ["+15555550910"],
            emailAddresses: []
        )
        try await realRepo.upsert(existing)

        let concurrentInteractionAt = Self.now.addingTimeInterval(-60)
        // Fires right as the reconciler would otherwise perform its own
        // field-scoped write — simulates a "mark caught up" write landing
        // on the exact same row between the reconciler's snapshot read
        // (already taken by this point) and its write, without needing
        // real thread-level concurrency to force the race.
        let interceptingRepo = InterceptingUpdateFieldsRepository(wrapping: realRepo) {
            var concurrentlyEdited = existing
            concurrentlyEdited.lastInteractedAt = concurrentInteractionAt
            try? await realRepo.upsert(concurrentlyEdited)
        }
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "concurrent-1", givenName: "New", familyName: "Name",
                          phoneNumbers: ["+15555550910"], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: interceptingRepo, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(refreshed: 1))
        let reloaded = try #require(try await realRepo.fetch(id: existing.id))
        // The reconciler's own system-owned field landed...
        #expect(reloaded.displayName == "New Name")
        // ...and so did the concurrent write to a field reconciliation
        // doesn't own. A whole-row `upsert` built from the reconciler's
        // stale snapshot would have reverted this back to `nil`.
        #expect(reloaded.lastInteractedAt == concurrentInteractionAt)
    }
}

/// Wraps a real `ContactRepository` and runs `onUpdateReconciledFields`
/// immediately before delegating the call — the seam a test uses to land a
/// concurrent write at the exact moment `ContactsReconciler` performs its
/// own field-scoped write.
private struct InterceptingUpdateFieldsRepository: ContactRepository {
    let wrapping: any ContactRepository
    let onUpdateReconciledFields: @Sendable () async -> Void

    func fetchAll() async throws -> [Contact] { try await wrapping.fetchAll() }
    func fetchTracked() async throws -> [Contact] { try await wrapping.fetchTracked() }
    func fetch(id: UUID) async throws -> Contact? { try await wrapping.fetch(id: id) }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        try await wrapping.fetchMembers(ofGroup: groupId)
    }
    func upsert(_ contact: Contact) async throws { try await wrapping.upsert(contact) }
    func archive(id: UUID, at: Date) async throws { try await wrapping.archive(id: id, at: at) }
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport {
        try await wrapping.fetchAllWithDiagnostics()
    }

    func updateReconciledFields(id: UUID, fields: ReconciledContactFields) async throws {
        await onUpdateReconciledFields()
        try await wrapping.updateReconciledFields(id: id, fields: fields)
    }
}
