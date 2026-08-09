import Foundation

/// The per-contact record (ARCHITECTURE.md §7). System Contacts remain the
/// source of truth — Regards holds a local mirror keyed by `systemContactRef`
/// for cadence, priority, channel, and tracking state.
public struct Contact: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let systemContactRef: String
    public var displayName: String
    public var photoRef: String?
    public var tracked: Bool
    public var cadenceDays: Int?
    public var priorityTier: PriorityTier
    public var preferredChannel: Channel
    public var preferredChannelValue: String
    public var phoneNumbers: [String]
    public var emailAddresses: [String]
    public var reminderWindowOverride: ReminderWindow?
    public var lastInteractedAt: Date?
    public var notes: String
    public var contactGroupId: UUID?
    public let createdAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        systemContactRef: String,
        displayName: String,
        photoRef: String? = nil,
        tracked: Bool = false,
        cadenceDays: Int? = nil,
        priorityTier: PriorityTier = .regular,
        preferredChannel: Channel = .phoneCall,
        preferredChannelValue: String = "",
        phoneNumbers: [String] = [],
        emailAddresses: [String] = [],
        reminderWindowOverride: ReminderWindow? = nil,
        lastInteractedAt: Date? = nil,
        notes: String = "",
        contactGroupId: UUID? = nil,
        createdAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.systemContactRef = systemContactRef
        self.displayName = displayName
        self.photoRef = photoRef
        self.tracked = tracked
        self.cadenceDays = cadenceDays
        self.priorityTier = priorityTier
        self.preferredChannel = preferredChannel
        self.preferredChannelValue = preferredChannelValue
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.reminderWindowOverride = reminderWindowOverride
        self.lastInteractedAt = lastInteractedAt
        self.notes = notes
        self.contactGroupId = contactGroupId
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    public var isActive: Bool { archivedAt == nil }
}

/// Virtual-merge target (ARCHITECTURE.md §7 `ContactGroup`). We never modify
/// the underlying system contacts — a group lives only in Regards' DB.
public struct ContactGroup: Sendable, Codable, Equatable, Hashable, Identifiable {
    public enum Origin: String, Codable, Sendable {
        case user               = "user"
        case suggestionAccepted = "suggestion_accepted"
    }

    public let id: UUID
    public var displayName: String
    public var primaryContactId: UUID
    public let createdAt: Date
    public let createdBy: Origin

    public init(
        id: UUID = UUID(),
        displayName: String,
        primaryContactId: UUID,
        createdAt: Date = Date(),
        createdBy: Origin = .user
    ) {
        self.id = id
        self.displayName = displayName
        self.primaryContactId = primaryContactId
        self.createdAt = createdAt
        self.createdBy = createdBy
    }
}
