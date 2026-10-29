import Foundation
import Testing
@testable import Regards

/// TF-11 slice 2: what the starter picker shows after a save that did not go
/// the simple way. The invariant behind every case here: after `save()` the
/// screen's picks are either what the store holds (so Done has nothing left to
/// offer) or they differ and Done is enabled to write the rest. Nothing may be
/// shown as saved that the store does not hold, and nothing may differ from
/// the store while Done is dead.
///
/// Saves go to a real in-memory GRDB store through a wrapper that can hold a
/// write open (`AsyncGate`, no sleeps) or make one call throw, so each race is
/// deterministic.
@MainActor
struct StarterContactsViewModelSaveTests {
    private static let importedAt = Date(timeIntervalSince1970: 1_790_000_000)

    @MainActor
    private final class Announcements {
        private(set) var messages: [String] = []
        func record(_ message: String) { messages.append(message) }
    }

    private static func person(_ name: String) -> Contact {
        Contact(systemContactRef: "save-\(name)", displayName: name, createdAt: importedAt)
    }

    private static func store() throws -> any ContactRepository {
        ProductionRepositoryFactory.makeEnvironment(database: try DatabaseFactory.makeInMemoryDatabase()).contacts
    }

    /// The store's tracked set as `[id: cadenceDays]`, the shape of
    /// `StarterContactsViewModel.selection`.
    private static func trackedInStore(_ store: any ContactRepository) async throws -> [UUID: Int] {
        var tracked: [UUID: Int] = [:]
        for contact in try await store.fetchAll() where contact.isCadenceEligible {
            tracked[contact.id] = contact.cadenceDays
        }
        return tracked
    }

    // MARK: Edits while a save is writing

    @Test("A pick and a cadence change made while Save is writing are never shown as saved without being written")
    func editsDuringSaveAreNotMarkedSaved() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        let cy = Self.person("Cy")
        for person in [ana, cy] { try await store.upsert(person) }
        let gate = AsyncGate()
        let repository = ScriptedTrackingContactRepository(store, gate: gate)
        let viewModel = StarterContactsViewModel(contacts: repository, announce: { _ in })
        await viewModel.load()
        viewModel.toggle(cy.id)

        let saving = Task { await viewModel.save() }
        // Cy's write has started with the default cadence of 14 and is held.
        await gate.waitUntilArrived()
        #expect(viewModel.isSaving)
        // Ana sorts before Cy, so the save loop is already past her.
        viewModel.toggle(ana.id)
        viewModel.setCadence(90, for: cy.id)
        await gate.open()
        _ = await saving.value

        let inStore = try await Self.trackedInStore(store)
        let screenMatchesStore = viewModel.selection == inStore
        #expect(
            screenMatchesStore || viewModel.canSave,
            "The screen differs from the store (\(viewModel.selection) vs \(inStore)) and Done is disabled."
        )
        // Cy's first write did land, whatever happened to the later edits.
        #expect(inStore[cy.id] != nil)
        #expect(!viewModel.isSaving)
    }

    @Test("Edits made while Save is writing are ignored, and the screen then matches the store")
    func editsDuringSaveAreIgnored() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        let cy = Self.person("Cy")
        for person in [ana, cy] { try await store.upsert(person) }
        let gate = AsyncGate()
        let repository = ScriptedTrackingContactRepository(store, gate: gate)
        let viewModel = StarterContactsViewModel(contacts: repository, announce: { _ in })
        await viewModel.load()
        viewModel.toggle(cy.id)
        let picksAtSaveStart = viewModel.selection
        #expect(picksAtSaveStart == [cy.id: StarterContactsViewModel.defaultCadenceDays])

        let saving = Task { await viewModel.save() }
        await gate.waitUntilArrived()
        #expect(viewModel.isSaving)
        let pickedAna = viewModel.toggle(ana.id)
        let unpickedCy = viewModel.toggle(cy.id)
        viewModel.setCadence(90, for: cy.id)
        #expect(!pickedAna)
        #expect(!unpickedCy)
        #expect(viewModel.selection == picksAtSaveStart, "Edits during Save must change nothing.")
        #expect(viewModel.cadenceDays(for: cy.id) == StarterContactsViewModel.defaultCadenceDays)
        await gate.open()
        let saved = await saving.value

        #expect(saved)
        let inStore = try await Self.trackedInStore(store)
        #expect(inStore == picksAtSaveStart)
        #expect(viewModel.selection == inStore)
        #expect(!viewModel.canSave, "Nothing differs from the store, so Done has nothing to write.")
        #expect(!viewModel.isSaving)
    }

    // MARK: A write that throws midway

    @Test("A save that fails on its second write leaves Done offering exactly the contact that was not written")
    func failedSaveMidwayResyncsAndDoneOffersTheRest() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        let ben = Self.person("Ben")
        for person in [ana, ben] { try await store.upsert(person) }
        let repository = ScriptedTrackingContactRepository(store, failOnCall: 2)
        let announcements = Announcements()
        let viewModel = StarterContactsViewModel(contacts: repository, announce: { announcements.record($0) })
        await viewModel.load()
        viewModel.toggle(ana.id)
        viewModel.toggle(ben.id)

        let saved = await viewModel.save()

        #expect(!saved)
        #expect(announcements.messages == [StarterContactsViewModel.saveFailedMessage])
        let afterFailure = try await Self.trackedInStore(store)
        #expect(afterFailure.keys.contains(ana.id))
        #expect(!afterFailure.keys.contains(ben.id))
        // Both picks are still on screen, and Done is on because Ben remains.
        #expect(viewModel.isSelected(ana.id) && viewModel.isSelected(ben.id))
        #expect(viewModel.canSave)

        // The retry writes only Ben: Ana's write was kept as the new baseline.
        let callsBeforeRetry = await repository.updateTrackingCalls
        let retried = await viewModel.save()

        #expect(retried)
        #expect(await repository.updateTrackingCalls == callsBeforeRetry + 1)
        #expect(try await Self.trackedInStore(store).keys.sorted { $0.uuidString < $1.uuidString }
            == [ana.id, ben.id].sorted { $0.uuidString < $1.uuidString })
        #expect(viewModel.selection == (try await Self.trackedInStore(store)))
        #expect(!viewModel.canSave)
    }

    // MARK: A pick archived mid-save

    @Test("When a pick is archived before Save, the message says who could not be saved and what was")
    func archivedPickIsNamedAndTheRestIsReported() async throws {
        let store = try Self.store()
        let leia = Self.person("Leia Organa")
        let han = Self.person("Han Solo")
        for person in [leia, han] { try await store.upsert(person) }
        let announcements = Announcements()
        let viewModel = StarterContactsViewModel(contacts: store, announce: { announcements.record($0) })
        await viewModel.load()
        viewModel.toggle(leia.id)
        viewModel.toggle(han.id)
        try await store.archive(id: leia.id, at: Self.importedAt)

        _ = await viewModel.save()

        let message = try #require(viewModel.statusMessage)
        #expect(announcements.messages == [message])
        #expect(message.contains("Leia Organa"), "The message must name who could not be saved: \(message)")
        let namesWhatWasSaved = message.contains("Han Solo") || message.contains("1 ")
        #expect(namesWhatWasSaved, "The message must say what was saved: \(message)")
        // Han's write went through; Leia's did not and is gone from the list.
        let inStore = try await Self.trackedInStore(store)
        #expect(inStore.keys.contains(han.id))
        #expect(!inStore.keys.contains(leia.id))
        // The archived contact leaves the list; the other pick stays.
        #expect(viewModel.contacts.map(\.id) == [han.id])
        #expect(viewModel.isSelected(han.id))
        // Done is on only if the screen still differs from the store.
        #expect(viewModel.canSave == (viewModel.selection != inStore))
    }
}

/// Wraps a repository so a test can hold the first `updateTracking` write open
/// on a gate, or make one numbered call throw. Everything else passes through.
private actor ScriptedTrackingContactRepository: ContactRepository {
    private let wrapped: any ContactRepository
    private let gate: AsyncGate?
    private let failOnCall: Int?
    private(set) var updateTrackingCalls = 0

    init(_ wrapped: any ContactRepository, gate: AsyncGate? = nil, failOnCall: Int? = nil) {
        self.wrapped = wrapped
        self.gate = gate
        self.failOnCall = failOnCall
    }

    func fetchAll() async throws -> [Contact] { try await wrapped.fetchAll() }
    func fetchTracked() async throws -> [Contact] { try await wrapped.fetchTracked() }
    func fetch(id: UUID) async throws -> Contact? { try await wrapped.fetch(id: id) }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        try await wrapped.fetchMembers(ofGroup: groupId)
    }
    func upsert(_ contact: Contact) async throws { try await wrapped.upsert(contact) }
    func archive(id: UUID, at: Date) async throws { try await wrapped.archive(id: id, at: at) }
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport {
        try await wrapped.fetchAllWithDiagnostics()
    }

    @discardableResult
    func updateTracking(id: UUID, cadenceDays: Int?) async throws -> Bool {
        updateTrackingCalls += 1
        let call = updateTrackingCalls
        if let gate, call == 1 { await gate.wait() }
        if call == failOnCall { throw RepositoryFakeFailure() }
        return try await wrapped.updateTracking(id: id, cadenceDays: cadenceDays)
    }
}
