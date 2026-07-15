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
    var reminderWindowOverride: String?
    var lastInteractedAt: Int?
    var notes: String
    var contactGroupId: String?
    var createdAt: Int
    var archivedAt: Int?

    init(from c: Contact) throws {
        self.id = c.id.uuidString
        self.systemContactRef = c.systemContactRef
        self.displayName = c.displayName
        self.photoRef = c.photoRef
        self.tracked = c.tracked
        self.cadenceDays = c.cadenceDays
        self.priorityTier = c.priorityTier.rawValue
        self.preferredChannel = c.preferredChannel.rawValue
        self.preferredChannelValue = c.preferredChannelValue
        if let window = c.reminderWindowOverride {
            self.reminderWindowOverride = try String(data: JSONEncoder().encode(window), encoding: .utf8)
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

        var windowOverride: ReminderWindow?
        if let json = reminderWindowOverride, let data = json.data(using: .utf8) {
            windowOverride = try JSONDecoder().decode(ReminderWindow.self, from: data)
        }

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

    init(from p: UserProfile) {
        self.id = 1
        self.onboardingCompletedAt = p.onboardingCompletedAt.map { Int($0.timeIntervalSince1970) }
        self.entitlementTier = p.entitlementTier.rawValue
        self.entitlementRefreshedAt = Int(p.entitlementRefreshedAt.timeIntervalSince1970)
    }

    func toDomain() -> UserProfile {
        UserProfile(
            onboardingCompletedAt: onboardingCompletedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            entitlementTier: EntitlementTier(rawValue: entitlementTier) ?? .free,
            entitlementRefreshedAt: Date(timeIntervalSince1970: TimeInterval(entitlementRefreshedAt))
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

    init(from w: ReminderWindow) throws {
        self.id = 1
        self.allowedDaysMask = w.allowedDays.rawValue
        self.allowedTimeRangesJson = String(
            data: try JSONEncoder().encode(w.allowedTimeRanges), encoding: .utf8) ?? "[]"
        if let q = w.quietHours {
            self.quietHoursJson = String(
                data: try JSONEncoder().encode(q), encoding: .utf8)
        } else {
            self.quietHoursJson = nil
        }
        self.timezone = w.timezoneIdentifier
    }

    func toDomain() throws -> ReminderWindow {
        let ranges: [TimeRange] = try JSONDecoder().decode(
            [TimeRange].self, from: Data(allowedTimeRangesJson.utf8))
        let quiet: TimeRange?
        if let json = quietHoursJson, let data = json.data(using: .utf8) {
            quiet = try JSONDecoder().decode(TimeRange.self, from: data)
        } else {
            quiet = nil
        }
        let window = ReminderWindow(
            allowedDays: DayOfWeekMask(rawValue: allowedDaysMask),
            allowedTimeRanges: ranges,
            quietHours: quiet,
            timezoneIdentifier: timezone
        )
        try window.validate()
        return window
    }
}

public enum DataError: Error, Equatable {
    case invalidUUID(String)
    case invalidEnum(String)
    case invalidChannel(String)
    case notFound
}
