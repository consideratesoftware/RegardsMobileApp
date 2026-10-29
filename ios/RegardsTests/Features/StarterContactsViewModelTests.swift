import Foundation
import GRDB
import Testing
@testable import Regards

/// TF-11 slice 2: the starter-contacts picker's state (§10.8, R14). The
/// owner's rules (2026-10-17, ruling 3): pick 1 to 3 people, skippable,
/// default cadence every 2 weeks, presets weekly / 2 weeks / monthly /
/// quarterly, sorted by name. The same view model backs the onboarding step
/// and the Settings re-entry, so these tests drive it through repositories
/// only and never through a screen.
///
/// Saves go to a real in-memory GRDB store where the test reads rows back, so
/// they exercise the shipped `updateTracking` write. Fakes cover the cases the
/// store can't produce: a failing read, a failing write, and a write counter.
/// Announcements go to an injected closure, so no test posts a real VoiceOver
/// announcement.
@MainActor
struct StarterContactsViewModelTests {
    private static let importedAt = Date(timeIntervalSince1970: 1_790_000_000)
    private static let loggedAt = Date(timeIntervalSince1970: 1_791_000_000)

    @MainActor
    private final class Announcements {
        private(set) var messages: [String] = []
        func record(_ message: String) { messages.append(message) }
    }

    private static func contact(
        _ name: String,
        tier: PriorityTier = .regular,
        archivedAt: Date? = nil,
        lastInteractedAt: Date? = nil
    ) -> Contact {
        Contact(
            systemContactRef: "starter-\(name)",
            displayName: name,
            priorityTier: tier,
            lastInteractedAt: lastInteractedAt,
            createdAt: importedAt,
            archivedAt: archivedAt
        )
    }

    private static func contact(tracked name: String, cadenceDays: Int) -> Contact {
        var contact = Self.contact(name)
        contact.tracked = true
        contact.cadenceDays = cadenceDays
        return contact
    }

    private static func viewModel(
        _ repository: any ContactRepository,
        _ announcements: Announcements = Announcements()
    ) -> StarterContactsViewModel {
        StarterContactsViewModel(contacts: repository, announce: { announcements.record($0) })
    }

    // MARK: Offering contacts

    @Test("Active contacts are offered sorted by name, whatever their tier or insertion order")
    func contactsAreOfferedSortedByName() async {
        let close = Self.contact("Zelda Close", tier: .close)
        let repository = StubContactRepository([
            Self.contact("mara"), close, Self.contact("Beth"), Self.contact("Álvaro"),
        ])
        let viewModel = Self.viewModel(repository)

        await viewModel.load()

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.contacts.map(\.displayName) == ["Álvaro", "Beth", "mara", "Zelda Close"])
    }

    @Test("Archived contacts are not offered")
    func archivedContactsAreNotOffered() async {
        let kept = Self.contact("Leia Organa")
        let gone = Self.contact("Han Solo", archivedAt: Self.loggedAt)
        let viewModel = Self.viewModel(StubContactRepository([kept, gone]))

        await viewModel.load()

        #expect(viewModel.contacts.map(\.id) == [kept.id])
        #expect(viewModel.filtered(searchText: "Han").isEmpty)
    }

    @Test("Search ignores case and diacritics in both directions")
    func searchFiltersByDiacriticInsensitiveName() async {
        let jose = Self.contact("José Álvarez")
        let zoe = Self.contact("Zoë Kravitz")
        let plain = Self.contact("Maria Plain")
        let viewModel = Self.viewModel(StubContactRepository([jose, zoe, plain]))
        await viewModel.load()

        #expect(viewModel.filtered(searchText: "jose").map(\.id) == [jose.id])
        #expect(viewModel.filtered(searchText: "ALVAREZ").map(\.id) == [jose.id])
        #expect(viewModel.filtered(searchText: "zoe").map(\.id) == [zoe.id])
        #expect(viewModel.filtered(searchText: "Zoë").map(\.id) == [zoe.id])
        #expect(viewModel.filtered(searchText: "Maria").map(\.id) == [plain.id])
        #expect(viewModel.filtered(searchText: "zzz").isEmpty)
        #expect(viewModel.filtered(searchText: "").map(\.id) == [jose.id, plain.id, zoe.id])
    }

    // MARK: Selecting

    @Test("A selected contact starts at the default cadence of every 2 weeks")
    func selectedContactDefaultsToTwoWeeks() async {
        let leia = Self.contact("Leia Organa")
        let viewModel = Self.viewModel(StubContactRepository([leia]))
        await viewModel.load()

        viewModel.toggle(leia.id)

        #expect(viewModel.isSelected(leia.id))
        #expect(viewModel.cadenceDays(for: leia.id) == 14)
    }

    @Test("The cadence presets are weekly, every 2 weeks, monthly and quarterly")
    func cadencePresetsMatchTheOwnerRuling() {
        #expect(StarterContactsViewModel.cadencePresets.map(\.days) == [7, 14, 30, 90])
        #expect(StarterContactsViewModel.cadencePresets.map(\.title).allSatisfy { !$0.isEmpty })
    }

    @Test("Toggling a selected contact deselects it")
    func togglingASelectedContactDeselectsIt() async {
        let leia = Self.contact("Leia Organa")
        let viewModel = Self.viewModel(StubContactRepository([leia]))
        await viewModel.load()
        viewModel.toggle(leia.id)

        viewModel.toggle(leia.id)

        #expect(!viewModel.isSelected(leia.id))
        #expect(viewModel.cadenceDays(for: leia.id) == nil)
        #expect(!viewModel.canSave)
    }

    @Test("A fourth selection is refused, announced, and leaves the first three alone")
    func fourthSelectionIsRefused() async {
        let people = ["Ana", "Ben", "Cy", "Di"].map { Self.contact($0) }
        let announcements = Announcements()
        let viewModel = Self.viewModel(StubContactRepository(people), announcements)
        await viewModel.load()
        for person in people.prefix(3) { viewModel.toggle(person.id) }
        #expect(announcements.messages.isEmpty)

        viewModel.toggle(people[3].id)

        #expect(!viewModel.isSelected(people[3].id))
        #expect(people.prefix(3).allSatisfy { viewModel.isSelected($0.id) })
        // The refusal must be visible and audible: a tap that did nothing
        // silently would look like a dead control.
        #expect(viewModel.statusMessage != nil)
        #expect(announcements.messages.count == 1)
        #expect(announcements.messages.first == viewModel.statusMessage)
    }

    @Test("Deselecting one of three frees a slot for another contact")
    func deselectingFreesASlot() async {
        let people = ["Ana", "Ben", "Cy", "Di"].map { Self.contact($0) }
        let viewModel = Self.viewModel(StubContactRepository(people))
        await viewModel.load()
        for person in people.prefix(3) { viewModel.toggle(person.id) }

        viewModel.toggle(people[0].id)
        viewModel.toggle(people[3].id)

        #expect(!viewModel.isSelected(people[0].id))
        #expect(viewModel.isSelected(people[3].id))
        #expect(viewModel.statusMessage == nil)
    }

    @Test("A selection made before searching survives the search")
    func selectionSurvivesSearch() async throws {
        let leia = Self.contact("Leia Organa")
        let han = Self.contact("Han Solo")
        let repository = StubContactRepository([leia, han])
        let viewModel = Self.viewModel(repository)
        await viewModel.load()
        viewModel.toggle(leia.id)

        #expect(viewModel.filtered(searchText: "han").map(\.id) == [han.id])
        let saved = await viewModel.save()

        #expect(saved)
        #expect(try await repository.fetch(id: leia.id)?.tracked == true)
        #expect(try await repository.fetch(id: han.id)?.tracked == false)
    }

    // MARK: Saving

    @Test("Save tracks only the selected contacts at their chosen cadence and moves nothing else")
    func saveTracksOnlySelectedWithCadence() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let repository = ProductionRepositoryFactory.makeEnvironment(database: database).contacts
        let people = [
            Self.contact("Ana"), Self.contact("Ben"), Self.contact("Cy"),
            Self.contact("Di", lastInteractedAt: Self.loggedAt), Self.contact("Eve"),
        ]
        for person in people { try await repository.upsert(person) }
        let before = try await Self.storedByID(repository)
        let viewModel = Self.viewModel(repository)
        await viewModel.load()
        viewModel.toggle(people[0].id)
        viewModel.toggle(people[2].id)
        viewModel.toggle(people[3].id)
        viewModel.setCadence(7, for: people[0].id)
        viewModel.setCadence(30, for: people[3].id)

        let saved = await viewModel.save()

        #expect(saved)
        let after = try await Self.storedByID(repository)
        #expect(after.values.filter(\.tracked).count == 3)
        #expect(after[people[0].id]?.cadenceDays == 7)
        #expect(after[people[2].id]?.cadenceDays == 14)
        #expect(after[people[3].id]?.cadenceDays == 30)
        for untouched in [people[1], people[4]] {
            #expect(after[untouched.id] == before[untouched.id])
        }
        for person in people {
            // Tracking never moves the anchor inputs (decision #29).
            #expect(after[person.id]?.createdAt == before[person.id]?.createdAt)
            #expect(after[person.id]?.lastInteractedAt == before[person.id]?.lastInteractedAt)
        }
    }

    @Test("Save announces how many people are now tracked, exactly once")
    func saveAnnouncesItsResult() async throws {
        let people = ["Ana", "Ben", "Cy"].map { Self.contact($0) }
        let announcements = Announcements()
        let viewModel = Self.viewModel(StubContactRepository(people), announcements)
        await viewModel.load()
        viewModel.toggle(people[0].id)
        viewModel.toggle(people[1].id)

        #expect(await viewModel.save())

        let message = try #require(announcements.messages.first)
        #expect(announcements.messages.count == 1)
        #expect(message.contains("2"))
    }

    @Test("A failed save keeps the selection, reports false, and announces the error once")
    func failedSaveKeepsSelectionAndAnnouncesError() async throws {
        let leia = Self.contact("Leia Organa")
        let announcements = Announcements()
        let repository = StubContactRepository.failingUpsert([leia])
        let viewModel = Self.viewModel(repository, announcements)
        await viewModel.load()
        viewModel.toggle(leia.id)
        viewModel.setCadence(30, for: leia.id)

        let saved = await viewModel.save()

        #expect(!saved)
        #expect(viewModel.isSelected(leia.id))
        #expect(viewModel.cadenceDays(for: leia.id) == 30)
        #expect(viewModel.statusMessage != nil)
        #expect(announcements.messages == [viewModel.statusMessage].compactMap { $0 })
        #expect(try await repository.fetch(id: leia.id)?.tracked == false)
    }

    @Test("With nothing selected there is nothing to save")
    func saveIsUnavailableWithNothingSelected() async {
        let viewModel = Self.viewModel(StubContactRepository([Self.contact("Leia Organa")]))
        await viewModel.load()

        #expect(!viewModel.canSave)
        #expect(!(await viewModel.save()))
    }

    // MARK: Skipping

    @Test("Skip writes nothing to the repository and drops the unsaved picks")
    func skipWritesNothing() async throws {
        let repository = RecordingWriteContactRepository()
        let leia = Self.contact("Leia Organa")
        try await repository.upsert(leia)
        await repository.resetWriteCount()
        let viewModel = Self.viewModel(repository)
        await viewModel.load()
        viewModel.toggle(leia.id)
        #expect(viewModel.isSelected(leia.id))

        viewModel.skip()

        #expect(await repository.writeCount() == 0)
        #expect(try await repository.fetch(id: leia.id)?.tracked == false)
        #expect(!viewModel.isSelected(leia.id))
    }

}

extension StarterContactsViewModelTests {
    // MARK: Contacts that were already tracked

    @Test("Contacts tracked before the screen opened start picked at their own cadence")
    func alreadyTrackedContactsStartPickedAtTheirCadence() async {
        let kept = Self.contact(tracked: "Ana", cadenceDays: 30)
        let other = Self.contact("Ben")
        let viewModel = Self.viewModel(StubContactRepository([kept, other]))

        await viewModel.load()

        #expect(viewModel.isSelected(kept.id))
        #expect(viewModel.cadenceDays(for: kept.id) == 30)
        #expect(!viewModel.isSelected(other.id))
        // Nothing has changed yet, so there is nothing to save.
        #expect(!viewModel.canSave)
    }

    @Test("Save writes only the contacts whose tracking changed")
    func saveWritesOnlyTheChangedContacts() async throws {
        let repository = RecordingWriteContactRepository()
        let kept = Self.contact(tracked: "Ana", cadenceDays: 30)
        let added = Self.contact("Ben")
        for person in [kept, added] { try await repository.upsert(person) }
        await repository.resetWriteCount()
        let viewModel = Self.viewModel(repository)
        await viewModel.load()
        viewModel.toggle(added.id)

        #expect(await viewModel.save())

        #expect(await repository.writeCount() == 1)
        #expect(try await repository.fetch(id: kept.id)?.cadenceDays == 30)
        #expect(try await repository.fetch(id: added.id)?.cadenceDays == 14)
    }

    @Test("Deselecting a tracked contact and saving untracks it and clears its cadence")
    func deselectingATrackedContactUntracksItOnSave() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let repository = ProductionRepositoryFactory.makeEnvironment(database: database).contacts
        let dropped = Self.contact(tracked: "Ana", cadenceDays: 30)
        let kept = Self.contact(tracked: "Ben", cadenceDays: 7)
        for person in [dropped, kept] { try await repository.upsert(person) }
        let viewModel = Self.viewModel(repository)
        await viewModel.load()

        viewModel.toggle(dropped.id)
        #expect(viewModel.canSave)
        #expect(await viewModel.save())

        let droppedAfter = try #require(try await repository.fetch(id: dropped.id))
        #expect(!droppedAfter.tracked)
        #expect(droppedAfter.cadenceDays == nil)
        let keptAfter = try #require(try await repository.fetch(id: kept.id))
        #expect(keptAfter.tracked)
        #expect(keptAfter.cadenceDays == 7)
    }

    @Test("More than 3 contacts tracked before the screen opened all start picked, and a cadence change untracks none")
    func oversizedTrackedSetIsKeptWhole() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let repository = ProductionRepositoryFactory.makeEnvironment(database: database).contacts
        let people = ["Ana", "Ben", "Cy", "Di", "Eve"].map { Self.contact(tracked: $0, cadenceDays: 14) }
        for person in people { try await repository.upsert(person) }
        let viewModel = Self.viewModel(repository)
        await viewModel.load()
        #expect(people.allSatisfy { viewModel.isSelected($0.id) })

        viewModel.setCadence(90, for: people[0].id)
        #expect(await viewModel.save())

        let tracked = try await repository.fetchTracked()
        #expect(Set(tracked.map(\.id)) == Set(people.map(\.id)))
        #expect(try await repository.fetch(id: people[0].id)?.cadenceDays == 90)
    }

    @Test("A contact that was archived while the screen was open fails the save with a message")
    func contactArchivedBeforeSaveFailsTheSave() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let repository = ProductionRepositoryFactory.makeEnvironment(database: database).contacts
        let leia = Self.contact("Leia Organa")
        let han = Self.contact("Han Solo")
        for person in [leia, han] { try await repository.upsert(person) }
        let announcements = Announcements()
        let viewModel = Self.viewModel(repository, announcements)
        await viewModel.load()
        viewModel.toggle(leia.id)
        viewModel.toggle(han.id)
        try await repository.archive(id: leia.id, at: Self.loggedAt)

        let saved = await viewModel.save()

        #expect(!saved)
        #expect(viewModel.statusMessage == StarterContactsViewModel.contactsChangedMessage)
        #expect(announcements.messages == [StarterContactsViewModel.contactsChangedMessage])
        // The archived contact is gone from the list; the other pick stays.
        #expect(viewModel.contacts.map(\.id) == [han.id])
        #expect(viewModel.isSelected(han.id))
    }

    // MARK: Cadence

    @Test("A cadence below 1 day or for a contact that isn't picked changes nothing")
    func invalidCadenceChangesAreIgnored() async {
        let leia = Self.contact("Leia Organa")
        let han = Self.contact("Han Solo")
        let viewModel = Self.viewModel(StubContactRepository([leia, han]))
        await viewModel.load()
        viewModel.toggle(leia.id)

        viewModel.setCadence(0, for: leia.id)
        viewModel.setCadence(-3, for: leia.id)
        viewModel.setCadence(7, for: han.id)

        #expect(viewModel.cadenceDays(for: leia.id) == 14)
        #expect(!viewModel.isSelected(han.id))
        #expect(viewModel.cadenceDays(for: han.id) == nil)
    }

    @Test("A tracked cadence outside the presets is listed so the menu can show it")
    func customCadenceIsListedAlongsidePresets() async {
        let custom = Self.contact(tracked: "Ana", cadenceDays: 10)
        let viewModel = Self.viewModel(StubContactRepository([custom]))
        await viewModel.load()

        let days = viewModel.cadenceChoices(for: custom.id).map(\.days)

        #expect(days == [7, 14, 30, 90, 10])
    }

    // MARK: Failure

    @Test("A failed load shows an error with nothing offered, and a retry recovers")
    func loadFailureShowsRetryableError() async {
        let leia = Self.contact("Leia Organa")
        let viewModel = Self.viewModel(FailsFirstReadContactRepository([leia]))

        await viewModel.load()

        #expect(viewModel.loadState == .failed)
        #expect(viewModel.contacts.isEmpty)
        #expect(!viewModel.canSave)

        await viewModel.load()

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.contacts.map(\.id) == [leia.id])
    }

    // MARK: Helpers

    private static func storedByID(_ repository: any ContactRepository) async throws -> [UUID: Contact] {
        Dictionary(uniqueKeysWithValues: try await repository.fetchAll().map { ($0.id, $0) })
    }
}

/// A repository whose first read throws and whose later reads succeed: the
/// shape of a transient failure, so a Retry can be proven to recover.
private actor FailsFirstReadContactRepository: ContactRepository {
    private let stored: SettableContactRepository
    private var failuresRemaining = 1

    init(_ contacts: [Contact]) {
        stored = SettableContactRepository(contacts: contacts)
    }

    func fetchAll() async throws -> [Contact] {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw RepositoryFakeFailure()
        }
        return try await stored.fetchAll()
    }

    func fetchTracked() async throws -> [Contact] { try await stored.fetchTracked() }
    func fetch(id: UUID) async throws -> Contact? { try await stored.fetch(id: id) }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        try await stored.fetchMembers(ofGroup: groupId)
    }
    func upsert(_ contact: Contact) async throws { try await stored.upsert(contact) }
    func archive(id: UUID, at: Date) async throws { try await stored.archive(id: id, at: at) }
}
