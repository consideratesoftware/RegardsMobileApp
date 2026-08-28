import Foundation
import Testing
@testable import Regards
/// Runs one behavior contract against the seeded in-memory mock and an
/// in-memory production database. Tests compare their own rows with the
/// pre-existing fixture so the shipping mock keeps its representative data.
enum RepositoryContractBackend: String, CaseIterable, Sendable {
    case grdb
    case mock

    func makeRepositories() throws -> RepositoryContractRepositories {
        switch self {
        case .grdb:
            let repositories = GRDBRepositories(
                dbQueue: try DatabaseFactory.makeInMemoryDatabase()
            )
            return RepositoryContractRepositories(
                contacts: repositories.contacts,
                groups: repositories.groups,
                reminders: repositories.reminders,
                interactions: repositories.interactions,
                window: repositories.window,
                profile: repositories.profile
            )
        case .mock:
            let repositories = MockRepositories(
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            return RepositoryContractRepositories(
                contacts: repositories.contacts,
                groups: repositories.groups,
                reminders: repositories.reminders,
                interactions: repositories.interactions,
                window: repositories.window,
                profile: repositories.profile
            )
        }
    }
}
struct RepositoryContractRepositories: Sendable {
    let contacts: any ContactRepository
    let groups: any ContactGroupRepository
    let reminders: any ReminderRepository
    let interactions: any InteractionRepository
    let window: any ReminderWindowRepository
    let profile: any UserProfileRepository
}
func contractUUID(_ suffix: Int) throws -> UUID {
    try #require(UUID(uuidString: String(
        format: "00000000-0000-0000-0000-%012d",
        suffix
    )))
}
// Not `private` (staged review round 10): `ReminderRepositoryContractTests`,
// split into its own file at the 500-line limit, needs both of these too.
func contractStoredDate(_ date: Date) -> Date {
    Date(timeIntervalSince1970: TimeInterval(Int(date.timeIntervalSince1970)))
}
func contractStored(_ reminder: ScheduledReminder) -> ScheduledReminder {
    var stored = reminder
    stored.scheduledFor = contractStoredDate(reminder.scheduledFor)
    return stored
}
private func contractStored(_ log: InteractionLog) -> InteractionLog {
    InteractionLog(id: log.id, contactId: log.contactId,
                   occurredAt: contractStoredDate(log.occurredAt),
                   source: log.source, channel: log.channel)
}
private func contractStored(_ contact: Contact) throws -> Contact { try ContactRecord(from: contact).toDomain() }
private func contractStored(_ g: ContactGroup) throws -> ContactGroup { try ContactGroupRecord(from: g).toDomain() }
private func contractStored(_ profile: UserProfile) -> UserProfile { UserProfileRecord(from: profile).toDomain() }
func expectWriteRejected(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected repository write to fail")
    } catch {}
}
func contractContact(
    id: UUID,
    suffix: String,
    tracked: Bool = false,
    groupID: UUID? = nil,
    archivedAt: Date? = nil
) -> Contact {
    Contact(
        id: id,
        systemContactRef: "repository-contract-\(suffix)",
        displayName: "Contract \(suffix)",
        photoRef: "photo-\(suffix)",
        tracked: tracked,
        cadenceDays: tracked ? 14 : nil,
        priorityTier: .close,
        preferredChannel: .email,
        preferredChannelValue: "\(suffix)@example.com",
        phoneNumbers: ["+1 415 555 0100"],
        emailAddresses: ["\(suffix)@example.com"],
        reminderWindowOverride: ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [
                TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 11)),
            ],
            timezoneIdentifier: "Etc/UTC",
            occasionTime: TimeOfDay(hour: 10, minute: 30),
            digestHorizonDays: 30
        ),
        lastInteractedAt: Date(timeIntervalSince1970: 1_700_000_100.875),
        notes: "Repository contract fixture",
        contactGroupId: groupID,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000.875),
        archivedAt: archivedAt
    )
}
struct ContactRepositoryContractTests {
    @Test("Contact timestamp normalization and full round-trip", arguments: RepositoryContractBackend.allCases)
    func upsertAndFetch(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let baselineIDs = Set(try await repositories.contacts.fetchAll().map(\.id))
        let contact = contractContact(
            id: try contractUUID(101),
            suffix: "upsert",
            tracked: true
        )

        try await repositories.contacts.upsert(contact)

        let fetched = try await repositories.contacts.fetch(id: contact.id)
        #expect(fetched == (try contractStored(contact)))
        let currentIDs = Set(try await repositories.contacts.fetchAll().map(\.id))
        #expect(currentIDs.subtracting(baselineIDs) == [contact.id])

        var updated = contact
        updated.displayName = "Updated contract contact"
        updated.phoneNumbers.append("+1 415 555 0199")
        try await repositories.contacts.upsert(updated)
        #expect(try await repositories.contacts.fetch(id: contact.id) == (try contractStored(updated)))

        let duplicateRef = contractContact(id: try contractUUID(102), suffix: "upsert")
        await expectWriteRejected { try await repositories.contacts.upsert(duplicateRef) }
        #expect(try await repositories.contacts.fetch(id: duplicateRef.id) == nil)
    }

    @Test("fetchTracked excludes untracked and archived contacts", arguments: RepositoryContractBackend.allCases)
    func trackedFilter(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let baselineIDs = Set(try await repositories.contacts.fetchTracked().map(\.id))
        let tracked = contractContact(
            id: try contractUUID(111), suffix: "tracked", tracked: true)
        let untracked = contractContact(
            id: try contractUUID(112), suffix: "untracked")
        let archived = contractContact(
            id: try contractUUID(113),
            suffix: "archived",
            tracked: true,
            archivedAt: Date(timeIntervalSince1970: 1_700_000_200.875)
        )

        for contact in [tracked, untracked, archived] {
            try await repositories.contacts.upsert(contact)
        }

        let currentIDs = Set(try await repositories.contacts.fetchTracked().map(\.id))
        #expect(currentIDs.subtracting(baselineIDs) == [tracked.id])
        #expect(!currentIDs.contains(untracked.id))
        #expect(!currentIDs.contains(archived.id))
    }

    @Test("archive keeps the row and normalizes archivedAt", arguments: RepositoryContractBackend.allCases)
    func archive(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(
            id: try contractUUID(121), suffix: "archive", tracked: true)
        let archivedAt = Date(timeIntervalSince1970: 1_800_000_100.875)
        try await repositories.contacts.upsert(contact)

        try await repositories.contacts.archive(id: contact.id, at: archivedAt)

        let fetched = try #require(try await repositories.contacts.fetch(id: contact.id))
        #expect(fetched.archivedAt == contractStoredDate(archivedAt))
        #expect(!fetched.isActive)
        #expect(!Set(try await repositories.contacts.fetchTracked().map(\.id)).contains(contact.id))
    }
}
struct ContactGroupRepositoryContractTests {

    @Test(
        "Group CRUD includes archived members and delete clears membership",
        arguments: RepositoryContractBackend.allCases
    )
    func groupLifecycle(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let baselineGroupIDs = Set(try await repositories.groups.fetchAll().map(\.id))
        let primaryID = try contractUUID(201)
        let memberID = try contractUUID(202)
        let group = ContactGroup(
            id: try contractUUID(203),
            displayName: "Contract group",
            primaryContactId: primaryID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.875),
            createdBy: .suggestionAccepted
        )

        try await repositories.contacts.upsert(contractContact(
            id: primaryID,
            suffix: "group-primary"
        ))
        try await repositories.groups.upsert(group)
        try await repositories.contacts.upsert(contractContact(
            id: primaryID,
            suffix: "group-primary",
            groupID: group.id
        ))
        try await repositories.contacts.upsert(contractContact(
            id: memberID,
            suffix: "group-member",
            groupID: group.id,
            archivedAt: Date(timeIntervalSince1970: 1_700_000_100.875)
        ))

        #expect(try await repositories.groups.fetch(id: group.id) == (try contractStored(group)))
        let currentGroupIDs = Set(try await repositories.groups.fetchAll().map(\.id))
        #expect(currentGroupIDs.subtracting(baselineGroupIDs) == [group.id])
        let members = try await repositories.contacts.fetchMembers(ofGroup: group.id)
        #expect(Set(members.map(\.id)) == [primaryID, memberID])
        #expect(members.first(where: { $0.id == memberID })?.isActive == false)

        try await repositories.groups.delete(id: group.id)

        #expect(try await repositories.groups.fetch(id: group.id) == nil)
        #expect(try await repositories.contacts.fetchMembers(ofGroup: group.id).isEmpty)
        #expect(try await repositories.contacts.fetch(id: primaryID)?.contactGroupId == nil)
        #expect(try await repositories.contacts.fetch(id: memberID)?.contactGroupId == nil)
    }

    @Test("Shipped foreign-key edges reject orphans", arguments: RepositoryContractBackend.allCases)
    func shippedForeignKeyEdges(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let missingContactID = try contractUUID(211)
        let orphanPrimaryGroup = ContactGroup(
            id: try contractUUID(212),
            displayName: "Unconstrained primary",
            primaryContactId: missingContactID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.875)
        )
        try await repositories.groups.upsert(orphanPrimaryGroup)
        #expect(try await repositories.groups.fetch(id: orphanPrimaryGroup.id) == (try contractStored(orphanPrimaryGroup)))

        let missingGroupID = try contractUUID(213)
        let orphanContact = contractContact(
            id: try contractUUID(214), suffix: "orphan-group", groupID: missingGroupID)
        await expectWriteRejected { try await repositories.contacts.upsert(orphanContact) }
        let orphanReminder = ScheduledReminder(
            contactId: missingContactID, kind: .cadence,
            scheduledFor: Date(timeIntervalSince1970: 1_800_000_000),
            osNotificationId: "orphan-reminder")
        await expectWriteRejected { try await repositories.reminders.upsert(orphanReminder) }
        let orphanInteraction = InteractionLog(
            contactId: missingContactID,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000), source: .manual)
        await expectWriteRejected { try await repositories.interactions.append(orphanInteraction) }
    }
}
struct InteractionRepositoryContractTests {

    @Test(
        "Recent interactions normalize timestamps, round-trip, scope, limit, and sort ties by id",
        arguments: RepositoryContractBackend.allCases
    )
    func recentOrdering(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(
            id: try contractUUID(401), suffix: "interaction-contact")
        let other = contractContact(
            id: try contractUUID(402), suffix: "interaction-other")
        try await repositories.contacts.upsert(contact)
        try await repositories.contacts.upsert(other)

        let oldest = InteractionLog(
            id: try contractUUID(411),
            contactId: contact.id,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000.875),
            source: .manual
        )
        let tiedFirst = InteractionLog(
            id: try contractUUID(412),
            contactId: contact.id,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_100.875),
            source: .reminderTap,
            channel: .signal
        )
        let tiedSecond = InteractionLog(
            id: try contractUUID(413),
            contactId: contact.id,
            occurredAt: tiedFirst.occurredAt,
            source: .reminderCaughtUp
        )
        let unrelated = InteractionLog(
            id: try contractUUID(414),
            contactId: other.id,
            occurredAt: tiedFirst.occurredAt,
            source: .manual
        )
        for log in [tiedSecond, unrelated, oldest, tiedFirst] {
            try await repositories.interactions.append(log)
        }

        let all = try await repositories.interactions.fetchRecent(forContact: contact.id, limit: 10)
        #expect(all == [contractStored(tiedFirst), contractStored(tiedSecond), contractStored(oldest)])
        let limited = try await repositories.interactions.fetchRecent(forContact: contact.id, limit: 2)
        #expect(limited == Array(all.prefix(2)))
        #expect(try await repositories.interactions.fetchRecent(
            forContact: contact.id, limit: 0).isEmpty)
        #expect(try await repositories.interactions.fetchRecent(
            forContact: contact.id, limit: -1).isEmpty)

        let duplicate = InteractionLog(
            id: tiedFirst.id, contactId: contact.id,
            occurredAt: Date(timeIntervalSince1970: 1_900_000_000),
            source: .manual, channel: .email)
        await expectWriteRejected { try await repositories.interactions.append(duplicate) }
        #expect(try await repositories.interactions.fetchRecent(forContact: contact.id, limit: 10) == all)
    }
}

struct SingletonRepositoryContractTests {
    @Test(
        "ReminderWindow saves valid values and preserves its row after rejection",
        arguments: RepositoryContractBackend.allCases
    )
    func reminderWindowValidation(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        _ = try await repositories.window.fetchGlobal()
        let updated = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [
                TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 12)),
            ],
            quietHours: nil,
            timezoneIdentifier: "America/Los_Angeles",
            occasionTime: TimeOfDay(hour: 10, minute: 30),
            digestHorizonDays: 30
        )
        try await repositories.window.saveGlobal(updated)
        #expect(try await repositories.window.fetchGlobal() == updated)

        let invalid = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [],
            timezoneIdentifier: "America/Los_Angeles"
        )
        do {
            try await repositories.window.saveGlobal(invalid)
            Issue.record("Expected saveGlobal to reject an invalid reminder window")
        } catch ReminderWindow.ValidationError.noAllowedTimeRanges {
            // Expected. A failed save must preserve the current singleton.
        } catch {
            Issue.record("Expected noAllowedTimeRanges, got \(error)")
        }
        #expect(try await repositories.window.fetchGlobal() == updated)
    }

    @Test("UserProfile timestamp normalization and overwrite", arguments: RepositoryContractBackend.allCases)
    func userProfileRoundTrip(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        _ = try await repositories.profile.fetch()
        let updated = UserProfile(
            onboardingCompletedAt: Date(timeIntervalSince1970: 1_800_000_000.875),
            entitlementTier: .lifetime,
            entitlementRefreshedAt: Date(timeIntervalSince1970: 1_800_000_100.875),
            trialStartedAt: Date(timeIntervalSince1970: 1_700_000_000.875)
        )

        try await repositories.profile.save(updated)

        #expect(try await repositories.profile.fetch() == contractStored(updated))
    }
}
