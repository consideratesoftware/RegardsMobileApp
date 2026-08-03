import Foundation
import Testing
@testable import Regards

private actor ScriptedContactRepository: ContactRepository {
    enum Step: Sendable {
        case success([Contact])
        case failure
    }

    enum TestError: Error {
        case unavailable
    }

    private var steps: [Step]

    init(steps: [Step]) {
        self.steps = steps
    }

    func fetchAll() async throws -> [Contact] {
        try await fetchTracked()
    }

    func fetchTracked() async throws -> [Contact] {
        guard !steps.isEmpty else { return [] }
        switch steps.removeFirst() {
        case let .success(contacts):
            return contacts
        case .failure:
            throw TestError.unavailable
        }
    }

    func fetch(id: UUID) async throws -> Contact? {
        nil
    }

    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        []
    }

    func upsert(_ contact: Contact) async throws {}

    func archive(id: UUID, at: Date) async throws {}
}

private actor ControllableContactRepository: ContactRepository {
    enum TestError: Error {
        case unavailable
    }

    private var nextRequestID = 0
    private var requests: [Int: CheckedContinuation<[Contact], any Error>] = [:]

    func fetchAll() async throws -> [Contact] {
        try await fetchTracked()
    }

    func fetchTracked() async throws -> [Contact] {
        let requestID = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            requests[requestID] = continuation
        }
    }

    func waitForRequestCount(_ count: Int) async {
        while nextRequestID < count {
            await Task.yield()
        }
    }

    func succeed(requestID: Int, contacts: [Contact]) {
        requests.removeValue(forKey: requestID)?.resume(returning: contacts)
    }

    func fail(requestID: Int) {
        requests.removeValue(forKey: requestID)?.resume(throwing: TestError.unavailable)
    }

    func fetch(id: UUID) async throws -> Contact? {
        nil
    }

    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        []
    }

    func upsert(_ contact: Contact) async throws {}

    func archive(id: UUID, at: Date) async throws {}
}

@MainActor
struct RegardsLoadStateTests {
    // MARK: - Fixtures

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func overdueContact(named displayName: String = "Alex Chen") -> Contact {
        Contact(
            systemContactRef: "load-state-\(displayName)",
            displayName: displayName,
            tracked: true,
            cadenceDays: 1,
            priorityTier: .close,
            preferredChannel: .signal,
            preferredChannelValue: "+14155550198",
            lastInteractedAt: now.addingTimeInterval(-3 * 86_400)
        )
    }

    // MARK: - Sequential load states

    @Test("Overdue clears failed data and a retry can recover")
    func overdueFailureAndRetry() async {
        let repository = ScriptedContactRepository(steps: [
            .success([Self.overdueContact()]),
            .failure,
            .success([]),
        ])
        let viewModel = OverdueViewModel(
            contacts: repository,
            clock: { Self.now }
        )

        #expect(viewModel.loadState == .loading)
        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.rows.count == 1)

        await viewModel.load()
        #expect(viewModel.loadState == .failed)
        #expect(viewModel.rows.isEmpty)

        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.rows.isEmpty)
    }

    @Test("Upcoming clears failed data and a retry can recover")
    func upcomingFailureAndRetry() async {
        let repository = ScriptedContactRepository(steps: [
            .success([Self.overdueContact()]),
            .failure,
            .success([]),
        ])
        let viewModel = UpcomingViewModel(
            contacts: repository,
            clock: { Self.now }
        )

        #expect(viewModel.loadState == .loading)
        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.totalCount == 1)
        #expect(viewModel.groups.count == 1)

        await viewModel.load()
        #expect(viewModel.loadState == .failed)
        #expect(viewModel.totalCount == 0)
        #expect(viewModel.groups.isEmpty)

        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.totalCount == 0)
        #expect(viewModel.groups.isEmpty)
    }

    @Test("Upcoming keeps an overdue contact in the active reminder slot")
    func upcomingIncludesActiveSlot() async throws {
        let timezone = try #require(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 3,
            hour: 18,
            minute: 30
        )))
        let contact = Contact(
            systemContactRef: "active-slot-contact",
            displayName: "Alex Chen",
            tracked: true,
            cadenceDays: 1,
            priorityTier: .close,
            preferredChannel: .signal,
            preferredChannelValue: "+14155550198",
            lastInteractedAt: now.addingTimeInterval(-3 * 86_400)
        )
        let repository = ScriptedContactRepository(steps: [.success([contact])])
        let viewModel = UpcomingViewModel(
            contacts: repository,
            window: .defaultV1(timezone: timezone),
            clock: { now }
        )

        await viewModel.load()

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.totalCount == 1)
        let row = try #require(viewModel.groups.first?.rows.first)
        let activeSlotStart = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 3,
            hour: 18
        )))
        #expect(row.contactId == contact.id)
        #expect(row.scheduledFor == activeSlotStart)
        #expect(row.timeOfDayText == "6:00 pm")
    }

    @Test("Contacts clears failed data and a retry can recover")
    func contactsFailureAndRetry() async {
        let repository = ScriptedContactRepository(steps: [
            .success([Self.overdueContact()]),
            .failure,
            .success([]),
        ])
        let viewModel = AllContactsViewModel(
            contacts: repository,
            clock: { Self.now }
        )

        #expect(viewModel.loadState == .loading)
        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.contacts.count == 1)
        #expect(viewModel.summary == "1 tracked")

        await viewModel.load()
        #expect(viewModel.loadState == .failed)
        #expect(viewModel.contacts.isEmpty)
        #expect(viewModel.summary == "Unavailable")

        await viewModel.load()
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.contacts.isEmpty)
        #expect(viewModel.summary == "0 tracked")
    }

    // MARK: - Overlapping loads and refresh

    @Test("Overdue ignores a stale failed load after a newer load succeeds")
    func overdueIgnoresStaleFailure() async {
        let repository = ControllableContactRepository()
        let viewModel = OverdueViewModel(contacts: repository, clock: { Self.now })

        let firstLoad = Task { await viewModel.load() }
        await repository.waitForRequestCount(1)
        let secondLoad = Task { await viewModel.load() }
        await repository.waitForRequestCount(2)

        await repository.succeed(requestID: 1, contacts: [Self.overdueContact()])
        await secondLoad.value
        await repository.fail(requestID: 0)
        await firstLoad.value

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.rows.count == 1)
    }

    @Test("Upcoming ignores a stale failed load after a newer load succeeds")
    func upcomingIgnoresStaleFailure() async {
        let repository = ControllableContactRepository()
        let viewModel = UpcomingViewModel(contacts: repository, clock: { Self.now })

        let firstLoad = Task { await viewModel.load() }
        await repository.waitForRequestCount(1)
        let secondLoad = Task { await viewModel.load() }
        await repository.waitForRequestCount(2)

        await repository.succeed(requestID: 1, contacts: [Self.overdueContact()])
        await secondLoad.value
        await repository.fail(requestID: 0)
        await firstLoad.value

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.totalCount == 1)
        #expect(viewModel.groups.count == 1)
    }

    @Test("Contacts ignores a stale failed load after a newer load succeeds")
    func contactsIgnoresStaleFailure() async {
        let repository = ControllableContactRepository()
        let viewModel = AllContactsViewModel(contacts: repository, clock: { Self.now })

        let firstLoad = Task { await viewModel.load() }
        await repository.waitForRequestCount(1)
        let secondLoad = Task { await viewModel.load() }
        await repository.waitForRequestCount(2)

        await repository.succeed(requestID: 1, contacts: [Self.overdueContact()])
        await secondLoad.value
        await repository.fail(requestID: 0)
        await firstLoad.value

        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.contacts.count == 1)
        #expect(viewModel.summary == "1 tracked")
    }

    @Test("Contacts keeps loaded content visible while refreshing")
    func contactsKeepsLoadedContentWhileRefreshing() async {
        let repository = ControllableContactRepository()
        let viewModel = AllContactsViewModel(contacts: repository, clock: { Self.now })

        let initialLoad = Task { await viewModel.load() }
        await repository.waitForRequestCount(1)
        await repository.succeed(requestID: 0, contacts: [Self.overdueContact()])
        await initialLoad.value

        let refresh = Task { await viewModel.load() }
        await repository.waitForRequestCount(2)
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.contacts.count == 1)

        await repository.succeed(requestID: 1, contacts: [])
        await refresh.value
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.contacts.isEmpty)
    }

    @Test("Overdue keeps loaded content visible while refreshing")
    func overdueKeepsLoadedContentWhileRefreshing() async {
        let repository = ControllableContactRepository()
        let viewModel = OverdueViewModel(contacts: repository, clock: { Self.now })

        let initialLoad = Task { await viewModel.load() }
        await repository.waitForRequestCount(1)
        await repository.succeed(requestID: 0, contacts: [Self.overdueContact()])
        await initialLoad.value

        let refresh = Task { await viewModel.load() }
        await repository.waitForRequestCount(2)
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.rows.count == 1)

        await repository.succeed(requestID: 1, contacts: [])
        await refresh.value
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.rows.isEmpty)
    }

    @Test("Upcoming keeps loaded content visible while refreshing")
    func upcomingKeepsLoadedContentWhileRefreshing() async {
        let repository = ControllableContactRepository()
        let viewModel = UpcomingViewModel(contacts: repository, clock: { Self.now })

        let initialLoad = Task { await viewModel.load() }
        await repository.waitForRequestCount(1)
        await repository.succeed(requestID: 0, contacts: [Self.overdueContact()])
        await initialLoad.value

        let refresh = Task { await viewModel.load() }
        await repository.waitForRequestCount(2)
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.totalCount == 1)

        await repository.succeed(requestID: 1, contacts: [])
        await refresh.value
        #expect(viewModel.loadState == .loaded)
        #expect(viewModel.totalCount == 0)
        #expect(viewModel.groups.isEmpty)
    }

    // MARK: - Contacts search

    @Test("Contacts search is a case-insensitive substring filter")
    func contactsSearchFiltering() async {
        let alex = Self.overdueContact()
        let maya = Self.overdueContact(named: "Maya Patel")
        let repository = ScriptedContactRepository(steps: [.success([alex, maya])])
        let viewModel = AllContactsViewModel(contacts: repository, clock: { Self.now })

        await viewModel.load()

        #expect(Set(viewModel.filtered(searchText: "").map(\.id)) == Set([alex.id, maya.id]))
        #expect(viewModel.filtered(searchText: "LEX") == [alex])
        #expect(viewModel.filtered(searchText: "pat") == [maya])
        #expect(viewModel.filtered(searchText: "nobody").isEmpty)
    }
}
