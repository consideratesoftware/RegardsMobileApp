import Foundation
import Observation
import SwiftUI

/// State behind the starter-contacts picker (TF-11, §14 PR29): choose up to 3
/// imported contacts to keep in touch with, and how often. The same screen
/// serves first-run onboarding and the Settings row "Choose people to keep in
/// touch with".
///
/// **What is offered.** Every active imported contact, sorted by name. Under
/// limited Contacts access the importer and reconciler only keep the shared
/// contacts active, so the shared subset is what shows here without any
/// extra filtering. Archived contacts are never offered.
///
/// **What Save writes.** Only the difference from what was tracked when the
/// list loaded, one `updateTracking` call per changed contact: a picked
/// contact gets its cadence, a contact that was tracked and is no longer
/// picked gets `nil` (untracked). `updateTracking` moves `tracked` and
/// `cadenceDays` and nothing else, so a foreground reconcile landing during
/// the save can't be reverted. `lastInteractedAt` stays nil, which keeps
/// `createdAt` as the anchor (decision #29). Skip writes nothing.
///
/// **The cap.** 3 picks. A 4th is refused with an inline message and an
/// announcement. Contacts that were already tracked before this screen opened
/// start picked even if there are more than 3, so opening and saving never
/// untracks anyone by surprise; the cap only stops adding.
@MainActor @Observable
final class StarterContactsViewModel {
    struct CadenceChoice: Equatable, Hashable, Sendable, Identifiable {
        let days: Int
        let title: String
        var id: Int { days }
    }

    static let maxSelection = 3
    static let defaultCadenceDays = 14
    static let cadencePresets = [
        CadenceChoice(days: 7, title: "Weekly"),
        CadenceChoice(days: 14, title: "Every 2 weeks"),
        CadenceChoice(days: 30, title: "Monthly"),
        CadenceChoice(days: 90, title: "Quarterly")
    ]

    static let limitMessage = "You can pick up to 3 people. Remove one to choose someone else."
    static let saveFailedMessage = "Couldn't save your picks. Try again."
    static let contactsChangedMessage =
        "Some people are no longer in your contacts. Check your picks, then save again."

    private(set) var loadState: RegardsLoadState = .loading
    /// Every offered contact, sorted by name.
    private(set) var contacts: [Contact] = []
    /// Picked contact ids with the cadence chosen for each.
    private(set) var selection: [UUID: Int] = [:]
    private(set) var isSaving = false
    /// The one inline message slot: a refused 4th pick or a save problem.
    /// Cleared by the next pick, cadence change, or save attempt.
    private(set) var statusMessage: String?

    private let repository: any ContactRepository
    private let announce: @MainActor (String) -> Void
    /// What was tracked when the list last loaded or saved. Save writes the
    /// difference between this and `selection`.
    @ObservationIgnored private var baseline: [UUID: Int] = [:]
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var loadGeneration = 0
    private static let log = RegardsLogger.feature("StarterContacts")

    init(
        contacts: any ContactRepository,
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.repository = contacts
        self.announce = announce
    }

    // MARK: - Reading

    /// Offered contacts matching the search text, ignoring case and accents
    /// ("jose" finds "José"). An empty or blank query shows everyone. The
    /// screen owns the text, as `AllContactsScreen` does.
    func filtered(searchText: String) -> [Contact] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return contacts }
        return contacts.filter { $0.displayName.localizedStandardContains(query) }
    }

    var selectedCount: Int { selection.count }

    /// "0 of 3 picked", "2 of 3 picked". Past 3 (more contacts were already
    /// tracked than the cap allows) it drops the "of 3", which would be wrong.
    var countSummary: String {
        if selection.count > Self.maxSelection { return "\(selection.count) picked" }
        return "\(selection.count) of \(Self.maxSelection) picked"
    }

    func isSelected(_ id: UUID) -> Bool { selection[id] != nil }

    func cadenceDays(for id: UUID) -> Int? { selection[id] }

    /// The 4 presets, plus the contact's current cadence when it is something
    /// else (a custom value tracked earlier), so the menu never shows a value
    /// it can't list.
    func cadenceChoices(for id: UUID) -> [CadenceChoice] {
        guard let days = selection[id], !Self.cadencePresets.contains(where: { $0.days == days }) else {
            return Self.cadencePresets
        }
        let title = CadenceDescriptor.describe(days: days).capitalizedFirst
        return Self.cadencePresets + [CadenceChoice(days: days, title: title)]
    }

    /// Whether Done has something to write. Picking nobody on a fresh install
    /// has nothing to save, so the screen's Skip is the way out.
    var canSave: Bool {
        loadState == .loaded && !isSaving && selection != baseline
    }

    // MARK: - Load

    /// Reads the offered contacts. The first successful load also picks the
    /// contacts that are already tracked; a later load (a retry, or the
    /// refresh after a failed save) keeps the user's picks, minus anyone no
    /// longer offered.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if loadState != .loaded { loadState = .loading }
        guard let snapshot = await readSnapshot() else {
            guard generation == loadGeneration else { return }
            contacts = []
            loadState = .failed
            return
        }
        guard generation == loadGeneration else { return }
        apply(snapshot)
        loadState = .loaded
    }

    // MARK: - Picking

    /// Picks or unpicks a contact. Returns `false` when a 4th pick is refused.
    /// A newly picked contact starts at every 2 weeks.
    @discardableResult
    func toggle(_ id: UUID) -> Bool {
        guard loadState == .loaded, contacts.contains(where: { $0.id == id }) else { return false }
        if selection[id] != nil {
            selection[id] = nil
            statusMessage = nil
            return true
        }
        guard selection.count < Self.maxSelection else {
            statusMessage = Self.limitMessage
            announce(Self.limitMessage)
            return false
        }
        selection[id] = Self.defaultCadenceDays
        statusMessage = nil
        return true
    }

    /// Changes the cadence of a picked contact. Ignored for one that isn't
    /// picked, and for a value below 1 day (`updateTracking` would refuse it).
    func setCadence(_ days: Int, for id: UUID) {
        guard selection[id] != nil, days >= 1 else { return }
        selection[id] = days
        statusMessage = nil
    }

    // MARK: - Finishing

    /// Writes the picks. Returns `true` when every write landed, so the screen
    /// can leave; on `false` the screen stays, the message says why, and
    /// nothing the user picked is lost.
    @discardableResult
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        defer { isSaving = false }
        statusMessage = nil

        var vanished = false
        do {
            for contact in contacts where selection[contact.id] != baseline[contact.id] {
                let landed = try await repository.updateTracking(id: contact.id, cadenceDays: selection[contact.id])
                if !landed { vanished = true }
            }
        } catch {
            Self.log.error("failed to save starter contacts: \(error, privacy: .private)")
            await resync()
            fail(Self.saveFailedMessage)
            return false
        }
        if vanished {
            await resync()
            fail(Self.contactsChangedMessage)
            return false
        }
        baseline = selection
        announce(savedAnnouncement())
        return true
    }

    /// Leaves without writing. Drops any unsaved picks so a screen that stays
    /// mounted (Settings) doesn't keep showing them.
    func skip() {
        selection = baseline
        statusMessage = nil
    }

    // MARK: - Private

    private func fail(_ text: String) {
        statusMessage = text
        announce(text)
    }

    /// Re-reads the store after a failed or partial save, so `baseline` matches
    /// what is really tracked and the next Save writes the right difference.
    /// If this read fails too, the old baseline stays: a retry rewrites the
    /// same values, which is harmless.
    private func resync() async {
        guard let snapshot = await readSnapshot() else { return }
        apply(snapshot)
    }

    private struct Snapshot {
        let offered: [Contact]
        let tracked: [UUID: Int]
    }

    private func readSnapshot() async -> Snapshot? {
        do {
            // The diagnostics read, so one unreadable row doesn't hide every
            // other contact (R50).
            let report = try await repository.fetchAllWithDiagnostics()
            let offered = report.contacts.filter(\.isActive).sorted { lhs, rhs in
                let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            var tracked: [UUID: Int] = [:]
            for contact in offered where contact.isCadenceEligible {
                tracked[contact.id] = contact.cadenceDays
            }
            return Snapshot(offered: offered, tracked: tracked)
        } catch {
            Self.log.error("failed to load starter contacts: \(error, privacy: .private)")
            return nil
        }
    }

    private func apply(_ snapshot: Snapshot) {
        contacts = snapshot.offered
        baseline = snapshot.tracked
        if hasLoaded {
            let offeredIds = Set(snapshot.offered.map(\.id))
            selection = selection.filter { offeredIds.contains($0.key) }
        } else {
            selection = snapshot.tracked
            hasLoaded = true
        }
    }

    private func savedAnnouncement() -> String {
        switch selection.count {
        case 0: "Saved. No one is picked."
        case 1: "Saved. Keeping in touch with 1 person."
        default: "Saved. Keeping in touch with \(selection.count) people."
        }
    }
}

private extension String {
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
