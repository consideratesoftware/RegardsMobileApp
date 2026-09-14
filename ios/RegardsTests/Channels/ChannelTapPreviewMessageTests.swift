import Foundation
import Testing
@testable import Regards

/// Parametric coverage for `Channel.tapPreviewMessage(for:)` (staged review
/// round 21 blocker): the two XCUI tests that reach it only assert an alert
/// appears, never its text, so a wrong verb on any branch shipped silently.
/// One exact expected string per channel, plus a completeness check so a
/// new §8 channel cannot land without choosing its preview.
struct ChannelTapPreviewMessageTests {

    static let name = "Leia Organa"
    static let pending = "Channel actions aren't wired up yet — this previews what tapping will do."

    static let expected: [Channel: String] = [
        .phoneCall: "Would call Leia Organa. \(pending)",
        .sms: "Would text Leia Organa. \(pending)",
        .facetime: "Would FaceTime Leia Organa. \(pending)",
        .email: "Would email Leia Organa. \(pending)",
        .whatsapp: "Would open WhatsApp with Leia Organa. \(pending)",
        .telegram: "Would open Telegram with Leia Organa. \(pending)",
        .signal: "Would open Signal with Leia Organa. \(pending)",
        .messenger: "Would open Messenger with Leia Organa. \(pending)",
        .instagramDM: "Would open Instagram with Leia Organa. \(pending)",
        .linkedinMsg: "Would open LinkedIn with Leia Organa. \(pending)",
        .discord: "Would open Discord with Leia Organa. \(pending)",
        // Pinned as shipped: `.custom` has no better verb than its display
        // name until TF-08 decides what a custom channel opens.
        .custom: "Would open Custom with Leia Organa. \(pending)",
        .inPerson: "Leia Organa's preferred channel is in person, so there's no app to open here — "
            + "this reminder is a nudge to reach out yourself."
    ]

    @Test("Every channel previews the exact tap message", arguments: Channel.allCases)
    func previewMessageMatches(channel: Channel) throws {
        let expected = try #require(Self.expected[channel], "no expected message for \(channel)")
        #expect(channel.tapPreviewMessage(for: Self.name) == expected)
    }

    @Test("The expected table covers every channel")
    func expectedTableIsComplete() {
        #expect(Set(Self.expected.keys) == Set(Channel.allCases))
    }

    @Test("The name is interpolated, not hardcoded")
    func nameIsInterpolated() {
        #expect(Channel.sms.tapPreviewMessage(for: "Han Solo").hasPrefix("Would text Han Solo."))
        #expect(Channel.inPerson.tapPreviewMessage(for: "Han Solo").hasPrefix("Han Solo's preferred channel"))
    }
}
