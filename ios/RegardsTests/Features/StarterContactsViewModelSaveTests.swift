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

    // MARK: Leaving the screen

    @Test("Skip pressed while Save is writing is refused, and the picks still match the store afterwards")
    func skipDuringSaveIsRefused() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        let cy = Self.person("Cy")
        for person in [ana, cy] { try await store.upsert(person) }
        let gate = AsyncGate()
        let viewModel = StarterContactsViewModel(
            contacts: ScriptedTrackingContactRepository(store, gate: gate),
            announce: { _ in }
        )
        await viewModel.load()
        viewModel.toggle(ana.id)
        viewModel.toggle(cy.id)

        let saving = Task { await viewModel.save() }
        // Ana's write is held; Cy's has not started.
        await gate.waitUntilArrived()
        let skipped = viewModel.skip()
        #expect(!skipped, "Skip must not leave while a write is in flight.")
        #expect(viewModel.selection.count == 2, "Refused Skip must not drop the picks being written.")
        await gate.open()
        let saved = await saving.value

        #expect(saved)
        let inStore = try await Self.trackedInStore(store)
        #expect(inStore.count == 2)
        #expect(viewModel.selection == inStore)
        #expect(!viewModel.canSave)
    }

    @Test("After a successful Save the screen is finished: picks, cadences, a second save and Skip all do nothing")
    func editsAfterDoneAreRefused() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        let cy = Self.person("Cy")
        for person in [ana, cy] { try await store.upsert(person) }
        let repository = ScriptedTrackingContactRepository(store)
        let viewModel = StarterContactsViewModel(contacts: repository, announce: { _ in })
        await viewModel.load()
        viewModel.toggle(ana.id)
        #expect(await viewModel.save())
        #expect(viewModel.isFinished)
        let written = try await Self.trackedInStore(store)
        let callsAfterDone = await repository.updateTrackingCalls

        let pickedCy = viewModel.toggle(cy.id)
        let unpickedAna = viewModel.toggle(ana.id)
        viewModel.setCadence(90, for: ana.id)
        let skipped = viewModel.skip()
        let savedAgain = await viewModel.save()

        #expect(!pickedCy && !unpickedAna && !skipped && !savedAgain)
        #expect(viewModel.selection == written, "A finished screen must keep showing what was written.")
        #expect(!viewModel.canSave)
        #expect(await repository.updateTrackingCalls == callsAfterDone, "No write after Done.")
        #expect(try await Self.trackedInStore(store) == written)
    }

    @Test("After Skip the screen is finished: picks, cadences and a save all do nothing")
    func editsAfterSkipAreRefused() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        try await store.upsert(ana)
        let repository = ScriptedTrackingContactRepository(store)
        let viewModel = StarterContactsViewModel(contacts: repository, announce: { _ in })
        await viewModel.load()
        viewModel.toggle(ana.id)

        let skipped = viewModel.skip()

        #expect(skipped)
        #expect(viewModel.isFinished)
        #expect(viewModel.selection.isEmpty, "Skip drops unsaved picks.")
        let pickedAgain = viewModel.toggle(ana.id)
        viewModel.setCadence(90, for: ana.id)
        let saved = await viewModel.save()
        #expect(!pickedAgain)
        #expect(!saved)
        #expect(viewModel.selection.isEmpty, "A finished screen must not show new picks.")
        #expect(!viewModel.canSave)
        #expect(await repository.updateTrackingCalls == 0, "Skip writes nothing, and nothing after it may.")
        #expect(try await Self.trackedInStore(store).isEmpty)
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

        let saved = await viewModel.save()

        // Han's write landed and Leia's could not, so the save is complete for
        // everyone who can still be saved: the screen is finished, and the
        // message (spoken, not shown, since the caller leaves) says who was left out.
        let message = "Saved. Keeping in touch with 1 person. Leia Organa is no longer in your contacts."
        #expect(saved)
        #expect(viewModel.isFinished)
        #expect(viewModel.statusMessage == message)
        #expect(announcements.messages == [message])
        #expect(!viewModel.statusIsProblem, "A partial save is a result, not a failure.")
        #expect(!viewModel.canSave)
        let inStore = try await Self.trackedInStore(store)
        #expect(inStore.keys.contains(han.id))
        #expect(!inStore.keys.contains(leia.id))
        // The archived contact leaves the list; the other pick stays.
        #expect(viewModel.contacts.map(\.id) == [han.id])
        #expect(viewModel.isSelected(han.id))
        #expect(viewModel.selection == inStore)
    }

    @Test("A tracked contact unpicked and then archived before Save is named, dropped, and not counted as saved")
    func unpickedTrackedContactArchivedBeforeSaveIsNamedAndDropped() async throws {
        let store = try Self.store()
        let leia = Self.person("Leia Organa")
        let han = Self.person("Han Solo")
        for person in [leia, han] { try await store.upsert(person) }
        #expect(try await store.updateTracking(id: leia.id, cadenceDays: 14))
        #expect(try await store.updateTracking(id: han.id, cadenceDays: 30))
        let repository = ScriptedTrackingContactRepository(store)
        let announcements = Announcements()
        let viewModel = StarterContactsViewModel(contacts: repository, announce: { announcements.record($0) })
        await viewModel.load()
        #expect(viewModel.selection.count == 2)
        viewModel.toggle(leia.id)
        try await store.archive(id: leia.id, at: Self.importedAt)

        let saved = await viewModel.save()

        let message = "Saved. Keeping in touch with 1 person. Leia Organa is no longer in your contacts."
        #expect(saved)
        #expect(viewModel.isFinished)
        #expect(viewModel.statusMessage == message)
        #expect(announcements.messages == [message])
        #expect(!viewModel.statusIsProblem)
        #expect(viewModel.contacts.map(\.id) == [han.id])
        #expect(viewModel.selection == [han.id: 30], "Han keeps his cadence and Leia is not counted.")
        // Only Leia's untrack was attempted: Han had nothing to write.
        #expect(await repository.updateTrackingCalls == 1)
    }

    @Test("A slow first load that finishes after a newer load does not overwrite the newer list")
    func staleLoadFinishingAfterNewerLoadIsDiscarded() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        let cy = Self.person("Cy")
        for person in [ana, cy] { try await store.upsert(person) }
        let readGate = AsyncGate()
        let repository = ScriptedTrackingContactRepository(store, readGate: readGate)
        let viewModel = StarterContactsViewModel(contacts: repository, announce: { _ in })
        let slowLoad = Task { await viewModel.load() }
        // The first read has Ana and Cy in hand and is held.
        await readGate.waitUntilArrived()
        try await store.archive(id: cy.id, at: Self.importedAt)

        await viewModel.load()
        #expect(viewModel.contacts.map(\.id) == [ana.id])
        await readGate.open()
        await slowLoad.value

        #expect(viewModel.contacts.map(\.id) == [ana.id], "The stale read must not bring Cy back.")
        #expect(viewModel.loadState == .loaded)
    }

    @Test("A failed save whose re-read also fails still remembers the writes that landed")
    func failedSaveWhoseResyncAlsoFailsKeepsLandedWritesAsBaseline() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        let ben = Self.person("Ben")
        for person in [ana, ben] { try await store.upsert(person) }
        // Read 1 is the load. Every read after it throws, the re-read included.
        let repository = ScriptedTrackingContactRepository(store, failOnCall: 2, failReadsFromCall: 2)
        let viewModel = StarterContactsViewModel(contacts: repository, announce: { _ in })
        await viewModel.load()
        viewModel.toggle(ana.id)
        viewModel.toggle(ben.id)

        let saved = await viewModel.save()

        #expect(!saved)
        #expect(viewModel.statusMessage == StarterContactsViewModel.saveFailedMessage)
        #expect(viewModel.statusIsProblem, "A failed save is a problem.")
        #expect(try await Self.trackedInStore(store).keys.contains(ana.id))
        #expect(viewModel.canSave, "Ben is still unwritten, so Done offers him.")
        let callsBeforeRetry = await repository.updateTrackingCalls

        let retried = await viewModel.save()

        #expect(retried)
        #expect(await repository.updateTrackingCalls == callsBeforeRetry + 1, "Ana's landed write is not repeated.")
        #expect(viewModel.selection == (try await Self.trackedInStore(store)))
    }
}

/// Wraps a repository so a test can hold the first `updateTracking` write open
/// on a gate, or make one numbered call throw. Everything else passes through.
private actor ScriptedTrackingContactRepository: ContactRepository {
    private let wrapped: any ContactRepository
    private let gate: AsyncGate?
    private let failOnCall: Int?
    private let readGate: AsyncGate?
    private let failReadsFromCall: Int?
    private(set) var updateTrackingCalls = 0
    private var readCalls = 0

    /// `readGate` holds the first diagnostics read open after it has read, so
    /// the caller gets a stale snapshot. `failReadsFromCall` makes that read
    /// number and every later one throw.
    init(
        _ wrapped: any ContactRepository,
        gate: AsyncGate? = nil,
        failOnCall: Int? = nil,
        readGate: AsyncGate? = nil,
        failReadsFromCall: Int? = nil
    ) {
        self.wrapped = wrapped
        self.gate = gate
        self.failOnCall = failOnCall
        self.readGate = readGate
        self.failReadsFromCall = failReadsFromCall
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
        readCalls += 1
        let call = readCalls
        if let failReadsFromCall, call >= failReadsFromCall { throw RepositoryFakeFailure() }
        let report = try await wrapped.fetchAllWithDiagnostics()
        if let readGate, call == 1 { await readGate.wait() }
        return report
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
