import Foundation
import Testing
@testable import Regards

/// `InteractionLogging` is the shared two-repository write behind "Caught up"
/// and "Log other channel…" (ARCHITECTURE.md §14 PR22, R11/R46). These tests
/// pin exactly what it touches — `InteractionLog` + `Contact.lastInteractedAt`
/// — and, just as importantly, what it never touches: `ScheduledReminder`
/// stays exclusively `SchedulingPass`'s job (decision #36), so this suite
/// never constructs a `ReminderRepository` at all.
struct InteractionLoggingTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func contact(
        id: UUID = UUID(),
        preferredChannel: Channel = .whatsapp,
        lastInteractedAt: Date? = nil
    ) -> Contact {
        Contact(
            id: id,
            systemContactRef: "sys-\(id.uuidString)",
            displayName: "Leia Organa",
            tracked: true,
            cadenceDays: 14,
            preferredChannel: preferredChannel,
            preferredChannelValue: "+14155550140",
            lastInteractedAt: lastInteractedAt
        )
    }

    @Test("Caught up logs .reminderCaughtUp against the contact's preferred channel")
    func markCaughtUpLogsPreferredChannel() async throws {
        let contact = Self.contact(preferredChannel: .signal, lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let logging = InteractionLogging(contacts: contacts, interactions: interactions)

        let updated = try await logging.markCaughtUp(contactId: contact.id, at: Self.now)

        #expect(updated.lastInteractedAt == Self.now)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == Self.now)

        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].contactId == contact.id)
        #expect(logs[0].source == .reminderCaughtUp)
        #expect(logs[0].channel == .signal)
        #expect(logs[0].occurredAt == Self.now)
    }

    @Test("Log other logs .manual against the chosen channel, not the preferred one")
    func logOtherLogsChosenChannel() async throws {
        let contact = Self.contact(preferredChannel: .whatsapp, lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let logging = InteractionLogging(contacts: contacts, interactions: interactions)

        let updated = try await logging.logOther(contactId: contact.id, channel: .email, at: Self.now)

        #expect(updated.lastInteractedAt == Self.now)
        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .manual)
        #expect(logs[0].channel == .email)
    }

    @Test("A later action moves lastInteractedAt forward")
    func markCaughtUpMovesLastInteractedAtForward() async throws {
        let earlier = Self.now.addingTimeInterval(-30 * 86_400)
        let contact = Self.contact(lastInteractedAt: earlier)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository()
        let logging = InteractionLogging(contacts: contacts, interactions: interactions)

        let updated = try await logging.markCaughtUp(contactId: contact.id, at: Self.now)

        #expect(updated.lastInteractedAt == Self.now)
        #expect(updated.lastInteractedAt != earlier)
    }

    @Test("An unknown contact throws notFound and logs nothing")
    func unknownContactThrowsAndLogsNothing() async throws {
        let contacts = StubContactRepository([])
        let interactions = StubInteractionRepository()
        let logging = InteractionLogging(contacts: contacts, interactions: interactions)

        do {
            _ = try await logging.markCaughtUp(contactId: UUID(), at: Self.now)
            Issue.record("Expected DataError.notFound")
        } catch DataError.notFound {
            // expected
        }

        let logs = await interactions.appendedLogs()
        #expect(logs.isEmpty)
    }

    @Test("A failing interaction write leaves the contact untouched")
    func failingInteractionWriteLeavesContactUntouched() async throws {
        let contact = Self.contact(lastInteractedAt: nil)
        let contacts = StubContactRepository([contact])
        let interactions = StubInteractionRepository.failing()
        let logging = InteractionLogging(contacts: contacts, interactions: interactions)

        do {
            _ = try await logging.markCaughtUp(contactId: contact.id, at: Self.now)
            Issue.record("Expected RepositoryFakeFailure")
        } catch is RepositoryFakeFailure {
            // expected
        }

        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == nil)
    }

    /// The reverse of the test above: `append` succeeds, then `upsert`
    /// fails. Pins the documented failure mode on `record(...)` — the log
    /// entry is left persisted with no matching `lastInteractedAt` move,
    /// not rolled back.
    @Test("A failing contact write after a successful interaction write leaves the log persisted")
    func failingContactWriteLeavesLogPersisted() async throws {
        let contact = Self.contact(lastInteractedAt: nil)
        let contacts = StubContactRepository.failingUpsert([contact])
        let interactions = StubInteractionRepository()
        let logging = InteractionLogging(contacts: contacts, interactions: interactions)

        do {
            _ = try await logging.markCaughtUp(contactId: contact.id, at: Self.now)
            Issue.record("Expected RepositoryFakeFailure")
        } catch is RepositoryFakeFailure {
            // expected
        }

        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == nil)
    }

    /// The archived-or-deleted-between-fetch-and-write race `record()`'s
    /// `guard matched else { throw DataError.notFound }` exists to catch
    /// (staged review round 6): the `fetch` at the top of `markCaughtUp`
    /// finds the contact, but by the time `updateLastInteractedAt` runs the
    /// row is gone — a concurrent `ContactsReconciler` archive, or another
    /// screen's delete — and the field-scoped write matches no row (`false`,
    /// not a thrown error). Distinct from `failingContactWriteLeavesLogPersisted`
    /// above: that test's write throws; this one's write returns cleanly
    /// with "nothing matched," which `record()` has to notice on its own
    /// rather than relying on a caught exception. The interaction log write
    /// already landed by then, so — same documented drift as `record()`'s
    /// own doc comment describes for "append succeeds, then the move
    /// throws" — it's provably left persisted even though the call as a
    /// whole throws.
    @Test("A contact removed between fetch and write throws notFound but leaves the log persisted")
    func removedBetweenFetchAndWriteThrowsButLeavesLogPersisted() async throws {
        let contact = Self.contact(lastInteractedAt: nil)
        let contacts = StubContactRepository.missingUpdateLastInteractedAt([contact])
        let interactions = StubInteractionRepository()
        let logging = InteractionLogging(contacts: contacts, interactions: interactions)

        do {
            _ = try await logging.markCaughtUp(contactId: contact.id, at: Self.now)
            Issue.record("Expected DataError.notFound")
        } catch DataError.notFound {
            // expected
        }

        let logs = await interactions.appendedLogs()
        #expect(logs.count == 1)
        #expect(logs[0].source == .reminderCaughtUp)
        let stored = try #require(await contacts.fetch(id: contact.id))
        #expect(stored.lastInteractedAt == nil)
    }
}
