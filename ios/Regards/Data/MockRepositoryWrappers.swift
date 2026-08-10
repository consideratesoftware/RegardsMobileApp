import Foundation

// MARK: - Protocol wrappers

struct MockContactRepository: ContactRepository {
    let store: MockStore
    func fetchAll() async throws -> [Contact] { await store.allContacts() }
    func fetchTracked() async throws -> [Contact] { await store.tracked() }
    func fetch(id: UUID) async throws -> Contact? { await store.contact(id: id) }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        await store.membersOfGroup(groupId)
    }
    func upsert(_ contact: Contact) async throws { try await store.upsertContact(contact) }
    func archive(id: UUID, at: Date) async throws { await store.archiveContact(id: id, at: at) }

    /// Overrides the protocol's default (fetch + apply + upsert) with the
    /// real field-scoped mock write, for parity with `GRDBContactRepository`.
    func updateReconciledFields(id: UUID, fields: ReconciledContactFields) async throws {
        await store.updateReconciledFields(id: id, fields: fields)
    }

    /// Overrides the protocol's default (which reports zero corruption for
    /// any in-memory backend) so the `REGARDS_UI_TEST_SEED_CORRUPT_ROW`
    /// fixture can make the All Contacts corruption banner reachable.
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport {
        ContactFetchReport(contacts: await store.allContacts(), corrupted: await store.corruptionDiagnosticsList())
    }
}

struct MockContactGroupRepository: ContactGroupRepository {
    let store: MockStore
    func fetchAll() async throws -> [ContactGroup] { await store.allGroups() }
    func fetch(id: UUID) async throws -> ContactGroup? { await store.group(id: id) }
    func upsert(_ group: ContactGroup) async throws { try await store.upsertGroup(group) }
    func delete(id: UUID) async throws { await store.deleteGroup(id: id) }
}

struct MockReminderRepository: ReminderRepository {
    let store: MockStore
    func fetchAllPending() async throws -> [ScheduledReminder] { await store.pendingReminders() }
    func fetchPending(forContact contactId: UUID) async throws -> [ScheduledReminder] {
        await store.pendingReminders(forContact: contactId)
    }
    func upsert(_ reminder: ScheduledReminder) async throws {
        try await store.upsertReminder(reminder)
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
    func append(_ log: InteractionLog) async throws { try await store.appendInteraction(log) }
}

struct MockReminderWindowRepository: ReminderWindowRepository {
    let store: MockStore
    func fetchGlobal() async throws -> ReminderWindow { try await store.getWindow() }
    func saveGlobal(_ window: ReminderWindow) async throws { try await store.setWindow(window) }
}

struct MockUserProfileRepository: UserProfileRepository {
    let store: MockStore
    func fetch() async throws -> UserProfile { await store.getProfile() }
    func save(_ profile: UserProfile) async throws { await store.setProfile(profile) }
}
