import SwiftUI

/// Monochrome line icon for each channel. PR3 uses SF Symbols as stand-ins —
/// Apple provides a broad catalog of phone/message/video glyphs that read
/// cleanly at small sizes and support Dynamic Type automatically. Replacing
/// the custom-SVG per-brand glyphs from the JSX mocks is tracked for a later
/// visual pass (branded logos risk trademark issues anyway).
///
/// Owner decision, staged review round 11 (the Overdue-row-crowding fix):
/// collapsed from one symbol per channel to exactly three, chosen by what
/// the action *does* rather than which app it opens — `phone.fill` for
/// `.phoneCall`, `video.fill` for `.facetime`, and a message-bubble symbol
/// for every other channel (`sms`, `email`, `whatsapp`, `telegram`,
/// `signal`, `messenger`, `instagramDM`, `linkedinMsg`, `discord`,
/// `inPerson`, `custom`). This is the one function from `Channel` to SF
/// Symbol, used at every `ChannelGlyph` call site — Overdue/Upcoming rows,
/// All Contacts rows, and Contact Detail's channel card all draw from it,
/// deliberately not forked per context. `.accessibilityHidden(true)` still
/// holds with only three symbols: the glyph was never the accessibility
/// source of truth. Callers that give the user a channel-specific action or
/// fact carry their own `.accessibilityLabel` built from
/// `Channel.displayName`/`channelLabel` — never from the glyph's SF Symbol
/// name — so the spoken channel identity stays exact (WhatsApp, Signal,
/// Messenger…) even though three of those now render identically:
/// Overdue's `channelPill`, Contact Detail's `primaryCTA` ("Open WhatsApp,
/// unavailable") and `channelSummary`. All Contacts' row is the one caller
/// that doesn't: the glyph there is purely decorative with no channel
/// action attached, so nothing on that row speaks channel identity today,
/// with or without this change — pre-existing, not a round-11 regression.
public struct ChannelGlyph: View {
    public let channel: Channel
    public let color: Color

    // `@ScaledMetric`, not a raw `CGFloat` (staged review round 11): the
    // previous fixed-point-size font meant this glyph never grew with
    // Dynamic Type at all, unlike the row text it used to sit beside.
    // `relativeTo: .body` scales `size` proportionally to the user's
    // Dynamic Type setting the same way system text does, so a caller's
    // `size` argument is still "the size at the default setting," not an
    // absolute point value.
    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 18

    public init(channel: Channel, size: CGFloat = 18, color: Color = RegardsDS.muted) {
        self.channel = channel
        self._scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
        self.color = color
    }

    public var body: some View {
        // Decorative glyph — `.accessibilityHidden(true)` means parents
        // (action pills, row metadata) own the VoiceOver label. Size is
        // caller-controlled so the glyph fits its pill / row at every
        // Dynamic Type setting without clipping. The audit's dynamic-type
        // check flags this as a known trade-off (noted in
        // `ios/docs/accessibility.md`).
        Image(systemName: Self.symbol(for: channel))
            .font(.system(size: scaledSize * 0.95, weight: .regular))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }

    static func symbol(for channel: Channel) -> String {
        switch channel {
        case .phoneCall:
            return "phone.fill"
        case .facetime:
            return "video.fill"
        case .sms, .email, .whatsapp, .telegram, .signal, .messenger,
             .instagramDM, .linkedinMsg, .discord, .inPerson, .custom:
            return "bubble.left.and.bubble.right.fill"
        }
    }
}
