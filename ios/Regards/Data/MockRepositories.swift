import Foundation

/// In-memory repository fakes preloaded with a Star Wars sample cast (Leia,
/// Padmé, Luke, Lando, Chewbacca, Anakin, Din, Shmi, Obi-Wan, Ahsoka). PR3's
/// SwiftUI shell renders against these so we can iterate on the screens — and
/// take demo screenshots — without integrating the Contacts framework.
public struct MockRepositories: Sendable {

    public let contacts: any ContactRepository
    public let groups: any ContactGroupRepository
    public let reminders: any ReminderRepository
    public let interactions: any InteractionRepository
    public let window: any ReminderWindowRepository
    public let profile: any UserProfileRepository

    public init(
        now: Date = MockRepositories.defaultNow,
        includeDuplicateFixture: Bool = false
    ) {
        let store = MockStore(
            now: now,
            includeDuplicateFixture: includeDuplicateFixture
        )
        self.contacts = MockContactRepository(store: store)
        self.groups = MockContactGroupRepository(store: store)
        self.reminders = MockReminderRepository(store: store)
        self.interactions = MockInteractionRepository(store: store)
        self.window = MockReminderWindowRepository(store: store)
        self.profile = MockUserProfileRepository(store: store)
    }

    /// Matches the JSX mock's anchor timestamp (screen-home.jsx `NOW`).
    public static let defaultNow: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 19
        comps.hour = 14; comps.minute = 0
        comps.timeZone = TimeZone(identifier: "Asia/Kolkata")
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }()
}

// MARK: - Shared in-memory store

/// Actor serializes mutations so concurrent callers don't trample state.
actor MockStore {
    var contacts: [UUID: Contact] = [:]
    var groups: [UUID: ContactGroup] = [:]
    var reminders: [UUID: ScheduledReminder] = [:]
    var interactions: [UUID: InteractionLog] = [:]
    var window: ReminderWindow
    var profile: UserProfile

    init(now: Date, includeDuplicateFixture: Bool) {
        self.window = ReminderWindow.defaultV1(timezone: TimeZone(identifier: "Asia/Kolkata") ?? .current)
        self.profile = UserProfile(onboardingCompletedAt: now.addingTimeInterval(-86_400 * 30),
                                    entitlementTier: .trial,
                                    entitlementRefreshedAt: now)

        for contact in Self.seedCast(
            now: now,
            includeDuplicateFixture: includeDuplicateFixture
        ) {
            self.contacts[contact.id] = contact
        }
    }

    static func seedCast(
        now: Date,
        includeDuplicateFixture: Bool
    ) -> [Contact] {
        let day: TimeInterval = 86_400
        var contacts = [
            Contact(
                systemContactRef: "sys-leia",
                displayName: "Leia Organa",
                tracked: true, cadenceDays: 14,
                priorityTier: .innerCircle,
                preferredChannel: .whatsapp,
                preferredChannelValue: "+91 98765 43210",
                lastInteractedAt: now.addingTimeInterval(-day * 23),
                notes: "Son is Ben. Ask about the diplomatic posting on Chandrila."),
            Contact(
                systemContactRef: "sys-padme",
                displayName: "Padmé Amidala",
                tracked: true, cadenceDays: 7,
                priorityTier: .innerCircle,
                preferredChannel: .phoneCall,
                preferredChannelValue: "+1 415 555 0134",
                lastInteractedAt: now.addingTimeInterval(-day * 11)),
            Contact(
                systemContactRef: "sys-luke",
                displayName: "Luke Skywalker",
                tracked: true, cadenceDays: 30,
                priorityTier: .close,
                preferredChannel: .signal,
                preferredChannelValue: "+1 415 555 0198",
                lastInteractedAt: now.addingTimeInterval(-day * 36)),
            Contact(
                systemContactRef: "sys-lando",
                displayName: "Lando Calrissian",
                tracked: true, cadenceDays: 21,
                priorityTier: .close,
                preferredChannel: .sms,
                preferredChannelValue: "+1 212 555 0176",
                lastInteractedAt: now.addingTimeInterval(-day * 23)),
            Contact(
                systemContactRef: "sys-chewbacca",
                displayName: "Chewbacca",
                tracked: true, cadenceDays: 30,
                priorityTier: .regular,
                preferredChannel: .whatsapp,
                preferredChannelValue: "+234 809 555 0122",
                lastInteractedAt: now.addingTimeInterval(-day * 28)),
            Contact(
                systemContactRef: "sys-anakin",
                displayName: "Anakin Skywalker",
                tracked: true, cadenceDays: 14,
                priorityTier: .innerCircle,
                preferredChannel: .phoneCall,
                preferredChannelValue: "+1 415 555 0177",
                lastInteractedAt: now.addingTimeInterval(-day * 8)),
            Contact(
                systemContactRef: "sys-din",
                displayName: "Din Djarin",
                tracked: true, cadenceDays: 42,
                priorityTier: .regular,
                preferredChannel: .signal,
                preferredChannelValue: "+92 300 5550132",
                lastInteractedAt: now.addingTimeInterval(-day * 42)),
            Contact(
                systemContactRef: "sys-shmi",
                displayName: "Shmi Skywalker",
                tracked: true, cadenceDays: 10,
                priorityTier: .innerCircle,
                preferredChannel: .phoneCall,
                preferredChannelValue: "+1 415 555 0111",
                lastInteractedAt: now.addingTimeInterval(-day * 2)),
            Contact(
                systemContactRef: "sys-obiwan",
                displayName: "Obi-Wan Kenobi",
                tracked: true, cadenceDays: 90,
                priorityTier: .regular,
                preferredChannel: .email,
                preferredChannelValue: "obiwan@jeditemple.org",
                lastInteractedAt: now.addingTimeInterval(-day * 84)),
            Contact(
                systemContactRef: "sys-ahsoka",
                displayName: "Ahsoka Tano",
                tracked: true, cadenceDays: 90,
                priorityTier: .close,
                preferredChannel: .phoneCall,
                preferredChannelValue: "+91 98100 00000",
                lastInteractedAt: now.addingTimeInterval(-day * 87)),
        ]
        if includeDuplicateFixture {
            contacts.append(Contact(
                systemContactRef: "ui-test-luke-duplicate",
                displayName: "Luke Skywalker",
                tracked: true,
                cadenceDays: 30,
                priorityTier: .close,
                preferredChannel: .signal,
                preferredChannelValue: "+1 415 555 0198",
                lastInteractedAt: now.addingTimeInterval(-day * 36)
            ))
        }
        return contacts
    }

    func allContacts() -> [Contact] { Array(contacts.values) }
    func tracked() -> [Contact] {
        contacts.values.filter { $0.tracked && $0.archivedAt == nil }
    }
    func contact(id: UUID) -> Contact? { contacts[id] }
    func membersOfGroup(_ groupId: UUID) -> [Contact] {
        contacts.values.filter { $0.contactGroupId == groupId }
    }
    func upsertContact(_ c: Contact) { contacts[c.id] = c }
    func archiveContact(id: UUID, at: Date) {
        guard var c = contacts[id] else { return }
        c.archivedAt = at
        contacts[id] = c
    }

    func allGroups() -> [ContactGroup] { Array(groups.values) }
    func group(id: UUID) -> ContactGroup? { groups[id] }
    func upsertGroup(_ g: ContactGroup) { groups[g.id] = g }
    func deleteGroup(id: UUID) { groups.removeValue(forKey: id) }

    func pendingReminders() -> [ScheduledReminder] {
        reminders.values.filter { $0.state == .pending }
            .sorted { $0.scheduledFor < $1.scheduledFor }
    }
    func pendingReminders(forContact id: UUID) -> [ScheduledReminder] {
        reminders.values.filter { $0.contactId == id && $0.state == .pending }
    }
    func upsertReminder(_ r: ScheduledReminder) { reminders[r.id] = r }
    func updateReminderState(id: UUID, state: ReminderState) {
        guard var r = reminders[id] else { return }
        r.state = state
        reminders[id] = r
    }
    func deleteReminder(id: UUID) { reminders.removeValue(forKey: id) }

    func recentInteractions(forContact id: UUID, limit: Int) -> [InteractionLog] {
        interactions.values.filter { $0.contactId == id }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }
    func appendInteraction(_ log: InteractionLog) { interactions[log.id] = log }

    func getWindow() -> ReminderWindow { window }
    func setWindow(_ w: ReminderWindow) { window = w }
    func getProfile() -> UserProfile { profile }
    func setProfile(_ p: UserProfile) { profile = p }
}

// MARK: - Protocol wrappers

struct MockContactRepository: ContactRepository {
    let store: MockStore
    func fetchAll() async throws -> [Contact] { await store.allContacts() }
    func fetchTracked() async throws -> [Contact] { await store.tracked() }
    func fetch(id: UUID) async throws -> Contact? { await store.contact(id: id) }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        await store.membersOfGroup(groupId)
    }
    func upsert(_ contact: Contact) async throws { await store.upsertContact(contact) }
    func archive(id: UUID, at: Date) async throws { await store.archiveContact(id: id, at: at) }
}

struct MockContactGroupRepository: ContactGroupRepository {
    let store: MockStore
    func fetchAll() async throws -> [ContactGroup] { await store.allGroups() }
    func fetch(id: UUID) async throws -> ContactGroup? { await store.group(id: id) }
    func upsert(_ group: ContactGroup) async throws { await store.upsertGroup(group) }
    func delete(id: UUID) async throws { await store.deleteGroup(id: id) }
}

struct MockReminderRepository: ReminderRepository {
    let store: MockStore
    func fetchAllPending() async throws -> [ScheduledReminder] { await store.pendingReminders() }
    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder] {
        await store.pendingReminders(forContact: contactId)
    }
    func upsert(_ reminder: ScheduledReminder) async throws {
        await store.upsertReminder(reminder)
    }
    func updateState(id: UUID, state: ReminderState) async throws {
        await store.updateReminderState(id: id, state: state)
    }
    func delete(id: UUID) async throws { await store.deleteReminder(id: id) }
}

struct MockInteractionRepository: InteractionRepository {
    let store: MockStore
    func fetchRecent(forContact contactId: UUID, limit: Int) async throws -> [InteractionLog] {
        await store.recentInteractions(forContact: contactId, limit: limit)
    }
    func append(_ log: InteractionLog) async throws { await store.appendInteraction(log) }
}

struct MockReminderWindowRepository: ReminderWindowRepository {
    let store: MockStore
    func fetchGlobal() async throws -> ReminderWindow { await store.getWindow() }
    func saveGlobal(_ window: ReminderWindow) async throws { await store.setWindow(window) }
}

struct MockUserProfileRepository: UserProfileRepository {
    let store: MockStore
    func fetch() async throws -> UserProfile { await store.getProfile() }
    func save(_ profile: UserProfile) async throws { await store.setProfile(profile) }
}
