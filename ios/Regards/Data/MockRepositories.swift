import Foundation

/// In-memory repository fakes preloaded with a Star Wars sample cast (Leia, Padmé, Luke, Lando, Chewbacca, Anakin,
/// Din, Shmi, Obi-Wan, Ahsoka), so the SwiftUI shell can render without integrating the Contacts framework.
public struct MockRepositories: Sendable {

    public let contacts: any ContactRepository
    public let groups: any ContactGroupRepository
    public let reminders: any ReminderRepository
    public let interactions: any InteractionRepository
    public let window: any ReminderWindowRepository
    public let profile: any UserProfileRepository

    public init(
        now: Date = MockRepositories.defaultNow,
        window: ReminderWindow = MockRepositories.defaultWindow,
        includeDuplicateFixture: Bool = false,
        seedCorruptRow: Bool = false
    ) {
        let store = MockStore(
            now: now,
            window: window,
            includeDuplicateFixture: includeDuplicateFixture,
            seedCorruptRow: seedCorruptRow
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

    public static let defaultWindow = ReminderWindow.defaultV1(
        timezone: TimeZone(identifier: "Asia/Kolkata") ?? .current
    )
}

// MARK: - Shared in-memory store

private func mockReminderPrecedes(
    _ lhs: ScheduledReminder,
    _ rhs: ScheduledReminder
) -> Bool {
    if lhs.scheduledFor != rhs.scheduledFor { return lhs.scheduledFor < rhs.scheduledFor }
    return lhs.id.uuidString < rhs.id.uuidString
}

private enum MockRepositoryWriteError: Error {
    case duplicateSystemContactRef, missingGroup, missingContact, duplicateInteraction
}

/// GRDB stores timestamps as integer epoch seconds; mock writes match so round trips, filtering, and ordering agree.
private func mockStoredDate(_ date: Date) -> Date {
    Date(timeIntervalSince1970: TimeInterval(Int(date.timeIntervalSince1970)))
}

private func mockStoredContact(_ contact: Contact) throws -> Contact { try ContactRecord(from: contact).toDomain() }

private func mockStoredGroup(_ group: ContactGroup) throws -> ContactGroup {
    try ContactGroupRecord(from: group).toDomain()
}

private func mockStoredReminder(_ reminder: ScheduledReminder) throws -> ScheduledReminder {
    try ScheduledReminderRecord(from: reminder).toDomain()
}

private func mockStoredInteraction(_ log: InteractionLog) throws -> InteractionLog {
    try InteractionLogRecord(from: log).toDomain()
}

private func mockStoredProfile(_ profile: UserProfile) -> UserProfile { UserProfileRecord(from: profile).toDomain() }

/// Actor serializes mutations so concurrent callers don't trample state.
actor MockStore {
    var contacts: [UUID: Contact] = [:]
    var groups: [UUID: ContactGroup] = [:]
    var reminders: [UUID: ScheduledReminder] = [:]
    var interactions: [UUID: InteractionLog] = [:]
    var window: ReminderWindow
    var profile: UserProfile
    /// R50 fixture (`REGARDS_UI_TEST_SEED_CORRUPT_ROW`): fabricated, not real (every mock write round-trips through
    /// `ContactRecord`) — exists so the XCUITest audit can reach the All Contacts corruption banner.
    var corruptionDiagnostics: [ContactCorruptionDiagnostic] = []

    /// Subscribers of `observeTracked()`, keyed per subscription so termination removes exactly one. Mirrors
    /// `GRDBContactRepository.observeTracked()`: nothing on subscribe, only the tracked set after a later write.
    private var trackedObservers: [UUID: AsyncStream<[Contact]>.Continuation] = [:]

    init(now: Date, window: ReminderWindow, includeDuplicateFixture: Bool, seedCorruptRow: Bool = false) {
        self.window = window
        self.profile = UserProfile(onboardingCompletedAt: now.addingTimeInterval(-86_400 * 30),
                                   entitlementTier: .trial,
                                   entitlementRefreshedAt: now)

        for contact in Self.seedCast(
            now: now,
            includeDuplicateFixture: includeDuplicateFixture
        ) {
            self.contacts[contact.id] = contact
        }

        let representative = Self.seedRepresentativeStates(
            now: now,
            window: window,
            contacts: contacts
        )
        contacts = representative.contacts
        groups = representative.groups
        reminders = representative.reminders
        interactions = representative.interactions

        if seedCorruptRow {
            corruptionDiagnostics = [
                ContactCorruptionDiagnostic(
                    rawId: "ui-test-corrupt-row",
                    systemContactRef: "ui-test-corrupt-row",
                    reason: "REGARDS_UI_TEST_SEED_CORRUPT_ROW fixture: simulates an undecodable stored row"
                ),
            ]
        }
    }

    /// Phase 0 deliberately renders representative persisted states (virtual merge marker, recent interactions, both
    /// occasion tags) so the corresponding UI isn't unreachable implementation. Local in-memory fixtures only —
    /// production scheduling still belongs to TF-07.
    private nonisolated static func seedRepresentativeStates(
        now: Date,
        window: ReminderWindow,
        contacts seededContacts: [UUID: Contact]
    ) -> (
        contacts: [UUID: Contact],
        groups: [UUID: ContactGroup],
        reminders: [UUID: ScheduledReminder],
        interactions: [UUID: InteractionLog]
    ) {
        let day: TimeInterval = 86_400
        var contacts = seededContacts
        var groups: [UUID: ContactGroup] = [:]
        var reminders: [UUID: ScheduledReminder] = [:]
        var interactions: [UUID: InteractionLog] = [:]

        if var leia = contacts.values.first(where: { $0.systemContactRef == "sys-leia" }) {
            let group = ContactGroup(
                displayName: "Leia Organa",
                primaryContactId: leia.id,
                createdAt: now.addingTimeInterval(-day * 120),
                createdBy: .suggestionAccepted
            )
            groups[group.id] = group
            leia.contactGroupId = group.id
            contacts[leia.id] = leia

            let archivedDuplicate = Contact(
                systemContactRef: "sys-leia-archived-duplicate",
                displayName: "Leia Organa",
                tracked: false,
                priorityTier: .innerCircle,
                preferredChannel: .email,
                preferredChannelValue: "leia@alderaan.example",
                contactGroupId: group.id,
                createdAt: now.addingTimeInterval(-day * 400),
                archivedAt: now.addingTimeInterval(-day * 90)
            )
            contacts[archivedDuplicate.id] = archivedDuplicate

            let recent = InteractionLog(
                contactId: leia.id,
                occurredAt: now.addingTimeInterval(-day * 23),
                source: .reminderCaughtUp,
                channel: .whatsapp
            )
            let earlier = InteractionLog(
                contactId: leia.id,
                occurredAt: now.addingTimeInterval(-day * 58),
                source: .manual,
                channel: .phoneCall
            )
            interactions[recent.id] = recent
            interactions[earlier.id] = earlier
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = window.timeZone
        let startOfToday = calendar.startOfDay(for: now)

        if let shmi = contacts.values.first(where: { $0.systemContactRef == "sys-shmi" }),
           let birthdayTime = Self.occasionInstant(
               daysAfter: startOfToday,
               offset: 1,
               hour: 9,
               calendar: calendar
           ) {
            let birthday = ScheduledReminder(
                contactId: shmi.id,
                kind: .birthday,
                occasionDate: Self.monthDayString(for: birthdayTime, calendar: calendar),
                occasionLabel: "Birthday",
                scheduledFor: birthdayTime,
                osNotificationId: "contact-\(shmi.id.uuidString)-\(ReminderKind.birthday.rawValue)"
            )
            reminders[birthday.id] = birthday
        }

        if let obiWan = contacts.values.first(where: { $0.systemContactRef == "sys-obiwan" }),
           let anniversaryTime = Self.occasionInstant(
               daysAfter: startOfToday,
               offset: 4,
               hour: 9,
               calendar: calendar
           ) {
            let anniversary = ScheduledReminder(
                contactId: obiWan.id,
                kind: .anniversary,
                occasionDate: Self.monthDayString(for: anniversaryTime, calendar: calendar),
                occasionLabel: "Jedi Order anniversary",
                scheduledFor: anniversaryTime,
                osNotificationId: "contact-\(obiWan.id.uuidString)-\(ReminderKind.anniversary.rawValue)"
            )
            reminders[anniversary.id] = anniversary
        }

        return (contacts, groups, reminders, interactions)
    }

    /// The seeded occasion instant `offset` days after `startOfToday`, at the given local `hour`.
    /// `date(bySettingHour:)` is `Optional`; the seeding used to sit in an `if let` that silently dropped occasions on
    /// nil, making R34's representative states unreachable with nothing to say so. A real DST gap (US Pacific,
    /// 2026-03-08, hour 2) never returns nil (the API snaps to 03:00), so this guard is defensive: fall forward to
    /// the first instant that exists, then to the day start if even that fails.
    nonisolated static func occasionInstant(
        daysAfter startOfToday: Date,
        offset: Int,
        hour: Int,
        calendar: Calendar
    ) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else {
            return nil
        }
        if let exact = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) {
            return exact
        }
        return calendar.nextDate(
            after: day,
            matching: DateComponents(hour: hour, minute: 0, second: 0),
            matchingPolicy: .nextTime,
            direction: .forward
        ) ?? day
    }

    private nonisolated static func monthDayString(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", components.month ?? 1, components.day ?? 1)
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
                preferredChannelValue: "+1 415 555 0140",
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
                preferredChannelValue: "+1 415 555 0141",
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
                preferredChannelValue: "+1 415 555 0142",
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
                preferredChannelValue: "obiwan@jeditemple.example",
                lastInteractedAt: now.addingTimeInterval(-day * 84)),
            Contact(
                systemContactRef: "sys-ahsoka",
                displayName: "Ahsoka Tano",
                tracked: true, cadenceDays: 90,
                priorityTier: .close,
                preferredChannel: .phoneCall,
                preferredChannelValue: "+1 415 555 0143",
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

}

extension MockStore {
    func allContacts() -> [Contact] { Array(contacts.values) }
    func corruptionDiagnosticsList() -> [ContactCorruptionDiagnostic] { corruptionDiagnostics }
    func tracked() -> [Contact] {
        contacts.values.filter { $0.tracked && $0.archivedAt == nil }
    }
    func contact(id: UUID) -> Contact? { contacts[id] }
    func membersOfGroup(_ groupId: UUID) -> [Contact] {
        contacts.values.filter { $0.contactGroupId == groupId }
    }
    func upsertContact(_ c: Contact) throws {
        try c.reminderWindowOverride?.validate()
        guard !contacts.values.contains(where: {
            $0.id != c.id && $0.systemContactRef == c.systemContactRef
        }) else { throw MockRepositoryWriteError.duplicateSystemContactRef }
        if let groupID = c.contactGroupId, groups[groupID] == nil {
            throw MockRepositoryWriteError.missingGroup
        }
        contacts[c.id] = try mockStoredContact(c)
        broadcastTrackedChange()
    }
    func archiveContact(id: UUID, at: Date) {
        guard var c = contacts[id] else { return }
        c.archivedAt = mockStoredDate(at)
        contacts[id] = c
        broadcastTrackedChange()
    }

    // MARK: - Live observation

    /// Never replays the current value on subscribe — only a later write reaches the stream (see
    /// `ContactRepository.observeTracked()`'s doc: an eager replay would race a caller's own optimistic update).
    /// Registers synchronously via `AsyncStream.makeStream`, not the closure initializer: that form can't touch
    /// actor-isolated `trackedObservers` directly, and deferring into a spawned `Task` could miss an early write.
    func observeTracked() -> AsyncStream<[Contact]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Contact].self)
        let token = UUID()
        trackedObservers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeTrackedObserver(token) }
        }
        return stream
    }

    private func removeTrackedObserver(_ token: UUID) {
        trackedObservers.removeValue(forKey: token)
    }

    private func broadcastTrackedChange() {
        let current = tracked()
        for continuation in trackedObservers.values {
            continuation.yield(current)
        }
    }

    /// Mirrors `GRDBContactRepository.updateReconciledFields`: reads the *current* entry (actor-isolated, so no
    /// stale snapshot) and overwrites only these five fields — parity for `ContactsReconciler` across backends.
    func updateReconciledFields(id: UUID, fields: ReconciledContactFields) {
        guard var c = contacts[id] else { return }
        c.displayName = fields.displayName
        c.phoneNumbers = fields.phoneNumbers
        c.emailAddresses = fields.emailAddresses
        c.preferredChannelValue = fields.preferredChannelValue
        c.archivedAt = fields.archivedAt.map(mockStoredDate)
        contacts[id] = c
    }

    func allGroups() -> [ContactGroup] { Array(groups.values) }
    func group(id: UUID) -> ContactGroup? { groups[id] }
    func upsertGroup(_ g: ContactGroup) throws { groups[g.id] = try mockStoredGroup(g) }
    func deleteGroup(id: UUID) {
        groups.removeValue(forKey: id)
        contacts = contacts.mapValues { contact in
            var updated = contact
            if updated.contactGroupId == id { updated.contactGroupId = nil }
            return updated
        }
        // GRDB's real FK `ON DELETE SET NULL` writes every member row, and `observeTracked()`'s region-based
        // observation fires on any write to the Contact table regardless of whether the *filtered* result changed —
        // so a subscriber sees a fresh (if content-identical) emission after a group delete there. Without this call
        // the mock silently drifted from that: a group delete never broadcast here, so a subscriber-driven parity
        // test comparing the two backends would see GRDB emit and the mock stay silent.
        broadcastTrackedChange()
    }

    func pendingReminders() -> [ScheduledReminder] {
        reminders.values.filter { $0.state == .pending }
            .sorted(by: mockReminderPrecedes)
    }
    func pendingReminders(forContact id: UUID) -> [ScheduledReminder] {
        reminders.values.filter { $0.contactId == id && $0.state == .pending }
            .sorted(by: mockReminderPrecedes)
    }
    func upsertReminder(_ r: ScheduledReminder) throws {
        guard contacts[r.contactId] != nil else { throw MockRepositoryWriteError.missingContact }
        reminders[r.id] = try mockStoredReminder(r)
    }
    func updateReminderState(id: UUID, state: ReminderState) {
        guard var r = reminders[id] else { return }
        r.state = state
        reminders[id] = r
    }
    func deleteReminder(id: UUID) { reminders.removeValue(forKey: id) }

    func recentInteractions(forContact id: UUID, limit: Int) -> [InteractionLog] {
        guard limit > 0 else { return [] }
        return interactions.values.filter { $0.contactId == id }
            .sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(limit)
            .map { $0 }
    }
    func appendInteraction(_ log: InteractionLog) throws {
        guard contacts[log.contactId] != nil else { throw MockRepositoryWriteError.missingContact }
        guard interactions[log.id] == nil else { throw MockRepositoryWriteError.duplicateInteraction }
        interactions[log.id] = try mockStoredInteraction(log)
    }

    func getWindow() throws -> ReminderWindow {
        try window.validate()
        return window
    }
    func setWindow(_ w: ReminderWindow) throws {
        try w.validate()
        window = w
    }
    func getProfile() -> UserProfile { profile }
    func setProfile(_ p: UserProfile) { profile = mockStoredProfile(p) }
}
