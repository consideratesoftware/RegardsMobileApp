import Foundation
import GRDB

// GRDB row types. Kept *outside* the Domain layer so the domain stays free of
// GRDB imports (enforced by the domain-purity CI guard).

struct ContactRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "Contact"

    var id: String
    var systemContactRef: String
    var displayName: String
    var photoRef: String?
    var tracked: Bool
    var cadenceDays: Int?
    var priorityTier: Int
    var preferredChannel: String
    var preferredChannelValue: String
    var phonesJson: String
    var emailsJson: String
    var reminderWindowOverride: String?
    var lastInteractedAt: Int?
    var notes: String
    var contactGroupId: String?
    var createdAt: Int
    var archivedAt: Int?

    init(from c: Contact) throws {
        try c.reminderWindowOverride?.validate()
        self.id = c.id.uuidString
        self.systemContactRef = c.systemContactRef
        self.displayName = c.displayName
        self.photoRef = c.photoRef
        self.tracked = c.tracked
        self.cadenceDays = c.cadenceDays
        self.priorityTier = c.priorityTier.rawValue
        self.preferredChannel = c.preferredChannel.rawValue
        self.preferredChannelValue = c.preferredChannelValue
        self.phonesJson = try encodeJSON(c.phoneNumbers)
        self.emailsJson = try encodeJSON(c.emailAddresses)
        if let window = c.reminderWindowOverride {
            self.reminderWindowOverride = try encodeJSON(window)
        } else {
            self.reminderWindowOverride = nil
        }
        self.lastInteractedAt = c.lastInteractedAt.map { Int($0.timeIntervalSince1970) }
        self.notes = c.notes
        self.contactGroupId = c.contactGroupId?.uuidString
        self.createdAt = Int(c.createdAt.timeIntervalSince1970)
        self.archivedAt = c.archivedAt.map { Int($0.timeIntervalSince1970) }
    }

    func toDomain() throws -> Contact {
        guard let id = UUID(uuidString: id) else { throw DataError.invalidUUID(id) }
        guard let channel = Channel(rawValue: preferredChannel) else {
            throw DataError.invalidChannel(preferredChannel)
        }
        let tier = PriorityTier(rawValue: priorityTier) ?? .regular
        let phoneNumbers = try decodeOptionalJSON([String].self, from: phonesJson) ?? []
        let emailAddresses = try decodeOptionalJSON([String].self, from: emailsJson) ?? []
        let windowOverride = try decodeOptionalJSON(
            ReminderWindow.self, from: reminderWindowOverride)
        try windowOverride?.validate()

        return Contact(
            id: id,
            systemContactRef: systemContactRef,
            displayName: displayName,
            photoRef: photoRef,
            tracked: tracked,
            cadenceDays: cadenceDays,
            priorityTier: tier,
            preferredChannel: channel,
            preferredChannelValue: preferredChannelValue,
            phoneNumbers: phoneNumbers,
            emailAddresses: emailAddresses,
            reminderWindowOverride: windowOverride,
            lastInteractedAt: lastInteractedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            notes: notes,
            contactGroupId: contactGroupId.flatMap(UUID.init(uuidString:)),
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            archivedAt: archivedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

struct ContactGroupRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ContactGroup"

    var id: String
    var displayName: String
    var primaryContactId: String
    var createdAt: Int
    var createdBy: String

    init(from g: ContactGroup) {
        self.id = g.id.uuidString
        self.displayName = g.displayName
        self.primaryContactId = g.primaryContactId.uuidString
        self.createdAt = Int(g.createdAt.timeIntervalSince1970)
        self.createdBy = g.createdBy.rawValue
    }

    func toDomain() throws -> ContactGroup {
        guard let id = UUID(uuidString: id),
              let primary = UUID(uuidString: primaryContactId) else {
            throw DataError.invalidUUID(self.id)
        }
        let origin = ContactGroup.Origin(rawValue: createdBy) ?? .user
        return ContactGroup(
            id: id,
            displayName: displayName,
            primaryContactId: primary,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            createdBy: origin
        )
    }
}

struct ScheduledReminderRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ScheduledReminder"

    var id: String
    var contactId: String
    var kind: String
    var occasionDate: String?
    var occasionLabel: String?
    var scheduledFor: Int
    var osNotificationId: String
    var state: String

    init(from r: ScheduledReminder) {
        self.id = r.id.uuidString
        self.contactId = r.contactId.uuidString
        self.kind = r.kind.rawValue
        self.occasionDate = r.occasionDate
        self.occasionLabel = r.occasionLabel
        self.scheduledFor = Int(r.scheduledFor.timeIntervalSince1970)
        self.osNotificationId = r.osNotificationId
        self.state = r.state.rawValue
    }

    func toDomain() throws -> ScheduledReminder {
        guard let id = UUID(uuidString: id),
              let contactId = UUID(uuidString: contactId) else {
            throw DataError.invalidUUID(self.id)
        }
        guard let kind = ReminderKind(rawValue: kind) else {
            throw DataError.invalidEnum(self.kind)
        }
        let state = ReminderState(rawValue: state) ?? .pending
        return ScheduledReminder(
            id: id,
            contactId: contactId,
            kind: kind,
            occasionDate: occasionDate,
            occasionLabel: occasionLabel,
            scheduledFor: Date(timeIntervalSince1970: TimeInterval(scheduledFor)),
            osNotificationId: osNotificationId,
            state: state
        )
    }
}

struct InteractionLogRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "InteractionLog"

    var id: String
    var contactId: String
    var occurredAt: Int
    var source: String
    var channel: String?

    init(from log: InteractionLog) {
        self.id = log.id.uuidString
        self.contactId = log.contactId.uuidString
        self.occurredAt = Int(log.occurredAt.timeIntervalSince1970)
        self.source = log.source.rawValue
        self.channel = log.channel?.rawValue
    }

    func toDomain() throws -> InteractionLog {
        guard let id = UUID(uuidString: id),
              let contactId = UUID(uuidString: contactId) else {
            throw DataError.invalidUUID(self.id)
        }
        guard let source = InteractionSource(rawValue: source) else {
            throw DataError.invalidEnum(self.source)
        }
        let channel = self.channel.flatMap(Channel.init(rawValue:))
        return InteractionLog(
            id: id,
            contactId: contactId,
            occurredAt: Date(timeIntervalSince1970: TimeInterval(occurredAt)),
            source: source,
            channel: channel
        )
    }
}

struct UserProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "UserProfile"

    var id: Int
    var onboardingCompletedAt: Int?
    var entitlementTier: String
    var entitlementRefreshedAt: Int
    var trialStartedAt: Int?

    init(from p: UserProfile) {
        self.id = 1
        self.onboardingCompletedAt = p.onboardingCompletedAt.map { Int($0.timeIntervalSince1970) }
        self.entitlementTier = p.entitlementTier.rawValue
        self.entitlementRefreshedAt = Int(p.entitlementRefreshedAt.timeIntervalSince1970)
        self.trialStartedAt = p.trialStartedAt.map { Int($0.timeIntervalSince1970) }
    }

    func toDomain() -> UserProfile {
        UserProfile(
            onboardingCompletedAt: onboardingCompletedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            entitlementTier: EntitlementTier(rawValue: entitlementTier) ?? .free,
            entitlementRefreshedAt: Date(timeIntervalSince1970: TimeInterval(entitlementRefreshedAt)),
            trialStartedAt: trialStartedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }
        )
    }
}

struct ReminderWindowRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "ReminderWindow"

    var id: Int
    var allowedDaysMask: Int
    var allowedTimeRangesJson: String
    var quietHoursJson: String?
    var timezone: String
    var occasionTime: String
    var digestHorizonDays: Int

    init(from w: ReminderWindow) throws {
        self.id = 1
        self.allowedDaysMask = w.allowedDays.rawValue
        self.allowedTimeRangesJson = try encodeJSON(w.allowedTimeRanges)
        if let q = w.quietHours {
            self.quietHoursJson = try encodeJSON(q)
        } else {
            self.quietHoursJson = nil
        }
        self.timezone = w.timezoneIdentifier
        self.occasionTime = Self.encodeTimeOfDay(w.occasionTime)
        self.digestHorizonDays = w.digestHorizonDays
    }

    func toDomain() throws -> ReminderWindow {
        let ranges: [TimeRange] = try JSONDecoder().decode(
            [TimeRange].self, from: Data(allowedTimeRangesJson.utf8))
        let quiet = try decodeOptionalJSON(TimeRange.self, from: quietHoursJson)
        let window = ReminderWindow(
            allowedDays: DayOfWeekMask(rawValue: allowedDaysMask),
            allowedTimeRanges: ranges,
            quietHours: quiet,
            timezoneIdentifier: timezone,
            occasionTime: try Self.decodeTimeOfDay(occasionTime),
            digestHorizonDays: digestHorizonDays
        )
        try window.validate()
        return window
    }

    private static func encodeTimeOfDay(_ time: TimeOfDay) -> String {
        String(format: "%02d:%02d", time.hour, time.minute)
    }

    private static func decodeTimeOfDay(_ value: String) throws -> TimeOfDay {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard value.count == 5,
              parts.count == 2,
              parts[0].count == 2,
              parts[1].count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0..<24).contains(hour),
              (0..<60).contains(minute) else {
            throw DataError.invalidTimeOfDay(value)
        }
        return TimeOfDay(hour: hour, minute: minute)
    }
}

private func decodeOptionalJSON<Value: Decodable>(
    _ type: Value.Type,
    from json: String?
) throws -> Value? {
    guard let json else { return nil }
    return try JSONDecoder().decode(Optional<Value>.self, from: Data(json.utf8))
}

private func encodeJSON<Value: Encodable>(_ value: Value) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let json = String(bytes: data, encoding: .utf8) else {
        throw DataError.invalidJSONEncoding
    }
    return json
}

public enum DataError: Error, Equatable {
    case invalidUUID(String)
    case invalidEnum(String)
    case invalidChannel(String)
    case invalidJSONEncoding
    case invalidTimeOfDay(String)
    case notFound
}
