import Foundation

/// Builds the `URL` that gets handed to the platform-open adapter
/// (ARCHITECTURE.md §8). Universal HTTPS links are preferred where available
/// (`wa.me`, `t.me`, `ig.me`, `m.me`) because they fall back to Safari when
/// the target app isn't installed and don't require an Info.plist declaration.
public enum DeepLinkBuilder {

    public static func build(channel: Channel, value: String) -> URL? {
        guard ChannelCatalog.validate(value: value, for: channel) else { return nil }

        let stripped = value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch channel {
        case .phoneCall:
            let phone = ChannelCatalog.normalizedPhone(stripped)
            return URL(string: "tel:\(phone)")
        case .sms:
            let phone = ChannelCatalog.normalizedPhone(stripped)
            return URL(string: "sms:\(phone)")
        case .facetime:
            if ChannelCatalog.isEmail(stripped) {
                return URL(string: "facetime:\(stripped)")
            }
            return URL(string: "facetime:\(ChannelCatalog.normalizedPhone(stripped))")
        case .email:
            return URL(string: "mailto:\(stripped)")
        case .whatsapp:
            let phone = ChannelCatalog.normalizedPhone(stripped)
            let phoneDigitsOnly = String(phone.drop(while: { $0 == "+" }))
            return URL(string: "https://wa.me/\(phoneDigitsOnly)")
        case .telegram:
            guard let handle = ChannelCatalog.normalizedHandle(stripped) else { return nil }
            return URL(string: "https://t.me/\(handle)")
        case .signal:
            let phone = ChannelCatalog.normalizedPhone(stripped)
            // Signal uses the full E.164 with '+' in the path.
            return URL(string: "https://signal.me/#p/\(phone)")
        case .messenger:
            guard let handle = ChannelCatalog.normalizedMessengerHandle(stripped) else { return nil }
            return URL(string: "https://m.me/\(handle)")
        case .instagramDM:
            guard let handle = ChannelCatalog.normalizedHandle(stripped) else { return nil }
            return URL(string: "https://ig.me/m/\(handle)")
        case .linkedinMsg:
            if let url = URL(string: stripped), url.scheme != nil { return url }
            return URL(string: "https://linkedin.com/in/\(stripped)")
        case .discord:
            // If the value contains a numeric Discord ID, use the DM deep link.
            if let id = discordUserId(from: stripped) {
                return URL(string: "discord://discord.com/users/\(id)")
            }
            return URL(string: "discord://")
        case .inPerson:
            return nil
        case .custom:
            guard let url = URL(string: stripped), url.scheme != nil else { return nil }
            return url
        }
    }

    /// Discord user IDs are 17-20 digit snowflakes. Users typically write
    /// `alexch#1234` or `alexch|123456789012345678` — we accept either form
    /// and extract the ID if present.
    static func discordUserId(from value: String) -> String? {
        // First try a trailing 17-20 digit run preceded by a separator.
        let digits = value.split(whereSeparator: { !$0.isNumber })
        if let last = digits.last, (17...20).contains(last.count) {
            return String(last)
        }
        return nil
    }
}
