import Foundation

/// Communication channels the V1 catalog supports (ARCHITECTURE.md §8).
///
/// Adding a channel requires an app update because iOS `canOpenURL` needs the
/// scheme declared in `LSApplicationQueriesSchemes` (populated in Phase 1 —
/// this enum is the source of truth for that list).
public enum Channel: String, CaseIterable, Codable, Sendable, Hashable {
    case phoneCall    = "phone_call"
    case sms          = "sms"
    case facetime     = "facetime"
    case email        = "email"
    case whatsapp     = "whatsapp"
    case telegram     = "telegram"
    case signal       = "signal"
    case messenger    = "messenger"
    case instagramDM  = "instagram_dm"
    case linkedinMsg  = "linkedin_msg"
    case discord      = "discord"
    case inPerson     = "in_person"
    case custom       = "custom"

    /// Human-readable name used in rows, detail screens, and deep-link CTAs.
    public var displayName: String {
        switch self {
        case .phoneCall:   return "Call"
        case .sms:         return "Text"
        case .facetime:    return "FaceTime"
        case .email:       return "Email"
        case .whatsapp:    return "WhatsApp"
        case .telegram:    return "Telegram"
        case .signal:      return "Signal"
        case .messenger:   return "Messenger"
        case .instagramDM: return "Instagram"
        case .linkedinMsg: return "LinkedIn"
        case .discord:     return "Discord"
        case .inPerson:    return "In person"
        case .custom:      return "Custom"
        }
    }

    /// Whether this channel is available on iOS. (Always true here — the
    /// catalog only lists iOS-supported channels; see §8.)
    public var isAvailableOnIOS: Bool { true }

    /// A natural-language preview of what tapping an Overdue/Upcoming row
    /// will eventually do, once TF-08 wires deep-link routing (owner
    /// decision, staged review round 12 — tap now previews the channel
    /// action instead of pushing Contact Detail). e.g. "Would call Padmé
    /// Amidala." or "Would open WhatsApp with Leia Organa." Deliberately a
    /// verb phrase, not `displayName` (a noun): `.phoneCall`/`.facetime`/
    /// `.sms`/`.email` are native system actions with their own ordinary-
    /// English verb; every third-party messaging app instead reads "open
    /// <app> with <name>," since there's no single English verb for
    /// "message someone on Telegram." `.inPerson` is not "pending TF-08"
    /// the way the others are — `ChannelCatalog.metadata` already documents
    /// it as having no deep link at all, ever, so its preview says that
    /// honestly instead of promising an app that will never open.
    public func tapPreviewMessage(for name: String) -> String {
        guard self != .inPerson else {
            return "\(name)'s preferred channel is in person, so there's no app to open here — "
                + "this reminder is a nudge to reach out yourself."
        }
        let verbPhrase: String
        switch self {
        case .phoneCall:  verbPhrase = "call \(name)"
        case .facetime:   verbPhrase = "FaceTime \(name)"
        case .sms:        verbPhrase = "text \(name)"
        case .email:      verbPhrase = "email \(name)"
        default:          verbPhrase = "open \(displayName) with \(name)"
        }
        return "Would \(verbPhrase). Channel actions aren't wired up yet — this previews what tapping will do."
    }
}
