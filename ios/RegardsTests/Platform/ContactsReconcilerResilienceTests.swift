import Foundation
import Testing
@testable import Regards

/// Resilience proofs for `ContactsReconciler`: rerun recovery after a
/// transient row failure, idempotence across repeated passes with no
/// change, delete-then-re-add identity semantics, and that archiving really
/// does preserve history rather than merely leaving the `Contact` row
/// intact.
struct ContactsReconcilerResilienceTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A reconcile rerun recovers a row that failed on the previous pass")
    func reconcileRerunRecoversPreviouslyFailedRow() async throws {
        let repo = OnceFailingContactRepository(failOnceForIdentifiers: ["flaky-1"])
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "ok-1", givenName: "OK", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
            SystemContact(identifier: "flaky-1", givenName: "Flaky", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let first = try await reconciler.reconcile()
        #expect(first == .init(imported: 1, failed: 1))
        #expect(Set(try await repo.fetchAll().map(\.systemContactRef)) == ["ok-1"])

        let second = try await reconciler.reconcile()
        #expect(second.imported == 1)
        #expect(second.failed == 0)
        #expect(Set(try await repo.fetchAll().map(\.systemContactRef)) == Set(["ok-1", "flaky-1"]))
    }

    @Test("Two reconcile passes over unchanged data write nothing on either pass")
    func reconcileIsIdempotentAcrossRepeatedPasses() async throws {
        let repo = RecordingWriteContactRepository()
        let existing = Contact(
            systemContactRef: "stable-1",
            displayName: "Stable",
            tracked: true,
            phoneNumbers: ["+15555550910"],
            emailAddresses: []
        )
        try await repo.upsert(existing)
        await repo.resetWriteCount()
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "stable-1", givenName: "Stable", familyName: "",
                          phoneNumbers: ["+15555550910"], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repo, clock: { Self.now })

        let first = try await reconciler.reconcile()
        #expect(first == .init(unchanged: 1))
        #expect(await repo.writeCount() == 0)

        let second = try await reconciler.reconcile()
        #expect(second == .init(unchanged: 1))
        #expect(await repo.writeCount() == 0)
    }

    @Test("A delete-then-re-add lands as a new row; the archived original keeps its history")
    func deleteThenReAddLandsAsNewRowKeepingArchivedHistory() async throws {
        let repo = GRDBRepositories(dbQueue: try DatabaseFactory.makeInMemoryDatabase()).contacts
        let original = Contact(
            systemContactRef: "old-identifier",
            displayName: "Original Person",
            tracked: true, cadenceDays: 21,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+15555550920"
        )
        // A bystander that stays visible across both passes keeps neither
        // fetch wholesale-empty — fix 3's mass-archive guard would otherwise
        // skip the deletion pass's sweep entirely.
        let bystander = Contact(systemContactRef: "bystander", displayName: "Bystander")
        try await repo.upsert(original)
        try await repo.upsert(bystander)
        let bystanderSystemContact = SystemContact(
            identifier: "bystander", givenName: "Bystander", familyName: "",
            phoneNumbers: [], emailAddresses: []
        )
        let deletionSource = MutableContactsSource(status: .authorized, contacts: [bystanderSystemContact])
        let deletionReconciler = ContactsReconciler(source: deletionSource, repo: repo, clock: { Self.now })
        _ = try await deletionReconciler.reconcile()
        let archivedOriginal = try #require(try await repo.fetch(id: original.id))
        #expect(archivedOriginal.archivedAt == Self.now)

        // The system re-issues a *new* identifier for what the user
        // perceives as "the same" re-added contact — CNContactStore never
        // reuses an identifier across a delete-then-re-add.
        let readdedAt = Self.now.addingTimeInterval(3_600)
        let readdSource = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "new-identifier", givenName: "Original", familyName: "Person",
                          phoneNumbers: ["+15555550920"], emailAddresses: []),
            bystanderSystemContact,
        ])
        let readdReconciler = ContactsReconciler(source: readdSource, repo: repo, clock: { readdedAt })

        let result = try await readdReconciler.reconcile()

        #expect(result == .init(imported: 1, unchanged: 1))
        let allContacts = try await repo.fetchAll()
        #expect(allContacts.count == 3)
        let stillActiveBystander = try #require(try await repo.fetch(id: bystander.id))
        #expect(stillActiveBystander.archivedAt == nil)
        let stillArchivedOriginal = try #require(try await repo.fetch(id: original.id))
        // The archived original's history-bearing fields are exactly as
        // they were the moment it was archived — a re-add never touches it.
        #expect(stillArchivedOriginal.archivedAt == Self.now)
        #expect(stillArchivedOriginal.tracked == true)
        #expect(stillArchivedOriginal.cadenceDays == 21)
        let newRow = try #require(allContacts.first { $0.systemContactRef == "new-identifier" })
        #expect(newRow.id != original.id)
        #expect(newRow.tracked == false)
        #expect(newRow.archivedAt == nil)
    }

    @Test("Archiving a contact preserves its ScheduledReminder and InteractionLog rows")
    func archiveSurvivesWithScheduledReminderAndInteractionLogHistory() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabase()
        let repositories = GRDBRepositories(dbQueue: dbQueue)
        let contact = Contact(
            systemContactRef: "with-history",
            displayName: "Has History",
            tracked: true,
            preferredChannel: .phoneCall,
            preferredChannelValue: "+15555550930"
        )
        try await repositories.contacts.upsert(contact)
        let reminder = ScheduledReminder(
            contactId: contact.id,
            kind: .cadence,
            scheduledFor: Self.now.addingTimeInterval(86_400),
            osNotificationId: "reminder-with-history"
        )
        try await repositories.reminders.upsert(reminder)
        let log = InteractionLog(
            contactId: contact.id,
            occurredAt: Self.now.addingTimeInterval(-86_400),
            source: .manual,
            channel: .phoneCall
        )
        try await repositories.interactions.append(log)

        // A still-visible bystander keeps the fetch from being
        // wholesale-empty — see fix 3's mass-archive guard.
        let bystander = Contact(systemContactRef: "bystander", displayName: "Bystander")
        try await repositories.contacts.upsert(bystander)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "bystander", givenName: "Bystander", familyName: "",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let reconciler = ContactsReconciler(source: source, repo: repositories.contacts, clock: { Self.now })

        let result = try await reconciler.reconcile()

        #expect(result == .init(archived: 1, unchanged: 1))
        let archivedContact = try #require(try await repositories.contacts.fetch(id: contact.id))
        #expect(archivedContact.archivedAt == Self.now)
        let survivingReminder = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(survivingReminder.map(\.id) == [reminder.id])
        let survivingLog = try await repositories.interactions.fetchRecent(forContact: contact.id, limit: 10)
        #expect(survivingLog.map(\.id) == [log.id])
    }
}
