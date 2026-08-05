import Foundation
import Testing
@testable import Regards

/// The spoken label for a Contact Detail interaction row.
///
/// The visual description joins its parts with a middle dot. VoiceOver reads
/// that character aloud, so the spoken form substitutes a comma. The
/// derivation lives on `InteractionEntry` rather than in `ContactDetailScreen`
/// so it can be asserted here, matching `UpcomingRowState.accessibilityLabel`.
@MainActor
struct ContactDetailInteractionLabelTests {

    @Test("The middle dot becomes a spoken comma")
    func middleDotBecomesAComma() {
        let entry = ContactDetailViewModel.InteractionEntry(
            id: UUID(),
            dateLabel: "3 days ago",
            descriptionLabel: "WhatsApp · reminder caught up"
        )

        #expect(entry.accessibilityLabel == "3 days ago, WhatsApp, reminder caught up")
        #expect(!entry.accessibilityLabel.contains("·"))
    }

    @Test("An entry with no description speaks only its date")
    func emptyDescriptionSpeaksOnlyTheDate() {
        let entry = ContactDetailViewModel.InteractionEntry(
            id: UUID(),
            dateLabel: "yesterday",
            descriptionLabel: ""
        )

        // No dangling comma.
        #expect(entry.accessibilityLabel == "yesterday")
    }

    @Test("A description without the separator is spoken verbatim")
    func descriptionWithoutSeparatorIsVerbatim() {
        let entry = ContactDetailViewModel.InteractionEntry(
            id: UUID(),
            dateLabel: "today",
            descriptionLabel: "Manual"
        )

        #expect(entry.accessibilityLabel == "today, Manual")
    }

    @Test("Every interaction source maps to a speakable label")
    func everySourceIsSpeakable() throws {
        let contactId = UUID()
        let occurredAt = Date(timeIntervalSince1970: 1_800_000_000)

        for source in InteractionSource.allCases {
            let log = InteractionLog(
                contactId: contactId,
                occurredAt: occurredAt,
                source: source,
                channel: .whatsapp
            )

            let label = ContactDetailViewModel.toEntry(log).accessibilityLabel

            #expect(!label.contains("·"))
            #expect(label.contains("WhatsApp"))
            // The raw enum case name must never reach VoiceOver.
            #expect(!label.contains("reminderCaughtUp"))
            #expect(!label.contains("reminderTap"))
        }
    }
}
