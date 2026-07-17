import Foundation

/// How Regards learned about this interaction.
public enum InteractionSource: String, Codable, Sendable, CaseIterable {
    case manual
    case reminderTap    = "reminder_tap"
    case reminderCaughtUp = "reminder_caught_up"
}

/// A single logged interaction (ARCHITECTURE.md §7 `InteractionLog`). The
/// "caught up" action writes one of these (`source: .reminderCaughtUp`) via
/// `InteractionRepository.append`; a manual "I talked to them" from Contact
/// Detail writes another (`source: .manual`). Wiring lands in PR22 (§14).
public struct InteractionLog: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let contactId: UUID
    public let occurredAt: Date
    public let source: InteractionSource
    public let channel: Channel?

    public init(
        id: UUID = UUID(),
        contactId: UUID,
        occurredAt: Date,
        source: InteractionSource,
        channel: Channel? = nil
    ) {
        self.id = id
        self.contactId = contactId
        self.occurredAt = occurredAt
        self.source = source
        self.channel = channel
    }
}
