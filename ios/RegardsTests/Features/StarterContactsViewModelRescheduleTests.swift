import Foundation
import Testing
@testable import Regards

/// TF-11 integration after TF-07c (§9: starter tracking is a cadence edit).
/// A `save()` that lands at least 1 write calls `onSaved` exactly once, before
/// it returns, with exactly the ids whose `updateTracking` returned true in
/// that call. In Settings `onSaved` runs `SchedulingPass.run(for:)` for each
/// id, so a tracking change reschedules before the screen closes.
extension StarterContactsViewModelSaveTests {
    @MainActor
    final class SavedCalls {
        private(set) var calls: [[UUID]] = []
        func record(_ ids: [UUID]) { calls.append(ids) }
    }

    private static func picker(
        _ repository: any ContactRepository,
        _ saved: SavedCalls
    ) -> StarterContactsViewModel {
        StarterContactsViewModel(contacts: repository, announce: { _ in }, onSaved: { saved.record($0) })
    }

    @Test("A Settings save reschedules exactly the contacts it tracked, untracked or re-timed, in one call")
    func settingsStarterSaveRunsThePassForChangedContacts() async throws {
        let store = try Self.store()
        let people = ["Ann", "Bea", "Cam", "Dee", "Eli"].map(Self.person)
        for person in people { try await store.upsert(person) }
        let (a, b, c, d) = (people[0], people[1], people[2], people[3])
        #expect(try await store.updateTracking(id: a.id, cadenceDays: 14))
        #expect(try await store.updateTracking(id: b.id, cadenceDays: 30))
        let saved = SavedCalls()
        let viewModel = Self.picker(store, saved)
        await viewModel.load()
        viewModel.toggle(a.id)
        viewModel.toggle(c.id)
        viewModel.setCadence(7, for: c.id)
        viewModel.toggle(d.id)

        #expect(await viewModel.save())

        #expect(saved.calls.count == 1)
        #expect(Set(saved.calls.first ?? []) == [a.id, c.id, d.id], "Bea was not changed, so she is not rescheduled.")
        #expect(saved.calls.first?.count == 3)
    }

    @Test("A cadence change alone reschedules that one contact")
    func cadenceChangeAloneRunsThePassForThatContact() async throws {
        let store = try Self.store()
        let bea = Self.person("Bea")
        let cam = Self.person("Cam")
        for person in [bea, cam] { try await store.upsert(person) }
        #expect(try await store.updateTracking(id: bea.id, cadenceDays: 30))
        #expect(try await store.updateTracking(id: cam.id, cadenceDays: 14))
        let saved = SavedCalls()
        let viewModel = Self.picker(store, saved)
        await viewModel.load()
        viewModel.setCadence(90, for: bea.id)

        #expect(await viewModel.save())

        #expect(saved.calls == [[bea.id]])
    }

    @Test("A save that throws on its second write still reschedules the first, which landed")
    func partialSaveFailureStillReschedulesLandedWrites() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        let ben = Self.person("Ben")
        for person in [ana, ben] { try await store.upsert(person) }
        let saved = SavedCalls()
        let viewModel = Self.picker(ScriptedTrackingContactRepository(store, failOnCall: 2), saved)
        await viewModel.load()
        viewModel.toggle(ana.id)
        viewModel.toggle(ben.id)

        let result = await viewModel.save()

        #expect(!result)
        #expect(saved.calls == [[ana.id]], "Ana's write landed, so she is rescheduled once.")

        // The retry writes only Ben, and reschedules only Ben.
        #expect(await viewModel.save())
        #expect(saved.calls == [[ana.id], [ben.id]])
    }

    @Test("A pick archived before Save is not rescheduled")
    func archivedPickIsNotRescheduled() async throws {
        let store = try Self.store()
        let cam = Self.person("Cam")
        let dee = Self.person("Dee")
        for person in [cam, dee] { try await store.upsert(person) }
        let saved = SavedCalls()
        let viewModel = Self.picker(store, saved)
        await viewModel.load()
        viewModel.toggle(cam.id)
        viewModel.toggle(dee.id)
        try await store.archive(id: cam.id, at: Self.importedAt)

        _ = await viewModel.save()

        #expect(saved.calls == [[dee.id]])
    }

    /// A pin: it passes on a view model that never calls `onSaved` at all, and
    /// fails only if a no-op save or Skip starts to. `noLandedWriteRunsNoPass`
    /// covers the saves that attempt writes and land none.
    @Test("A save with nothing to write and a Skip reschedule nothing")
    func skipRunsNoPass() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        try await store.upsert(ana)
        let saved = SavedCalls()
        let viewModel = Self.picker(store, saved)
        await viewModel.load()

        let savedNothing = await viewModel.save()
        viewModel.toggle(ana.id)
        let skipped = viewModel.skip()

        #expect(!savedNothing)
        #expect(skipped)
        #expect(saved.calls.isEmpty)
    }

    @Test("A save that lands no write reschedules nothing, whether the first write throws or every pick vanished")
    func noLandedWriteRunsNoPass() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        let ben = Self.person("Ben")
        for person in [ana, ben] { try await store.upsert(person) }

        // The first write throws, so nothing landed.
        let thrown = SavedCalls()
        let failing = Self.picker(ScriptedTrackingContactRepository(store, failOnCall: 1), thrown)
        await failing.load()
        failing.toggle(ana.id)
        let failedResult = await failing.save()
        #expect(!failedResult)
        #expect(thrown.calls.isEmpty, "Nothing landed, so nothing is rescheduled.")

        // Every pick is archived before Save, so every write returns false.
        let vanished = SavedCalls()
        let archiving = Self.picker(store, vanished)
        await archiving.load()
        archiving.toggle(ana.id)
        archiving.toggle(ben.id)
        try await store.archive(id: ana.id, at: Self.importedAt)
        try await store.archive(id: ben.id, at: Self.importedAt)
        _ = await archiving.save()
        #expect(vanished.calls.isEmpty, "Archived contacts are not rescheduled, and no empty call is made.")
    }

    @Test("Save does not return, and the screen is not finished, until the reschedule returns", .timeLimit(.minutes(1)))
    func onSavedFinishesBeforeSaveReturns() async throws {
        let store = try Self.store()
        let ana = Self.person("Ana")
        try await store.upsert(ana)
        let gate = AsyncGate()
        let viewModel = StarterContactsViewModel(
            contacts: store, announce: { _ in }, onSaved: { _ in await gate.wait() }
        )
        await viewModel.load()
        viewModel.toggle(ana.id)

        let saving = Task { await viewModel.save() }
        await gate.waitUntilArrived()

        // The write has landed and the pass is running: Done still reads
        // "Saving…", and Settings must not pop yet.
        #expect(viewModel.isSaving)
        #expect(!viewModel.isFinished)
        #expect(try await Self.trackedInStore(store).keys.contains(ana.id))
        await gate.open()
        let result = await saving.value

        #expect(result)
        #expect(!viewModel.isSaving)
        #expect(viewModel.isFinished)
    }
}
