import SwiftUI

/// Contact Detail's card sections, split out of `ContactDetailScreen.swift`
/// when that file reached SwiftLint's 500-line `file_length` limit under
/// `--strict`. A pure move: same views, same labels, same identifiers, which
/// `ScreensAccessibilityTests` asserts exactly.
///
/// These call `detailRow`, `stubAction`, `nextReminderLabel`, and
/// `valueColor`, which is why the sections extension in that file is no
/// longer `private` — see the comment at its declaration.
extension ContactDetailScreen {

    // MARK: - Cards

    func cadenceCard(contact: Contact) -> some View {
        VStack(spacing: 0) {
            SectionHeader("Cadence")
            RegardsCard {
                VStack(spacing: 0) {
                    detailRow(
                        label: "Every",
                        value: viewModel.cadenceLabel,
                        action: "Change",
                        actionIdentifier: "contact-detail.cadence-change-unavailable"
                    )
                    Hair(inset: 16)
                    detailRow(label: "Next reminder", value: nextReminderLabel(contact: contact),
                              isAccent: true)
                    Hair(inset: 16)
                    detailRow(label: "Last talked", value: viewModel.lastTalkedLabel)
                    Hair(inset: 16)
                    detailRow(
                        label: "Status",
                        value: statusValue,
                        isDanger: viewModel.overdueSummary.isOverdue,
                        valueFocus: $isStatusFocused
                    )
                }
            }
        }
    }

    func channelCard(contact: Contact) -> some View {
        VStack(spacing: 0) {
            SectionHeader("Preferred channel")
            RegardsCard {
                AccessibilityAdaptiveLayout {
                    HStack(spacing: 12) {
                        channelSummary(contact: contact)
                        Spacer()
                        stubAction(
                            "Change",
                            identifier: "contact-detail.channel-change-unavailable"
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                } accessibility: {
                    VStack(alignment: .leading, spacing: 12) {
                        channelSummary(contact: contact)
                        stubAction(
                            "Change",
                            identifier: "contact-detail.channel-change-unavailable"
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    func channelSummary(contact: Contact) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(RegardsDS.accentSoft)
                    .frame(width: 36, height: 36)
                ChannelGlyph(channel: contact.preferredChannel, size: 18, color: RegardsDS.accentInk)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.preferredChannel.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(RegardsDS.ink)
                Text(contact.preferredChannelValue)
                    .font(RegardsFont.mono(.footnote))
                    .foregroundStyle(RegardsDS.muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.channelSummaryAccessibilityLabel(contact: contact))
        .accessibilityIdentifier("contact-detail.channel-summary")
    }

    var interactionsCard: some View {
        VStack(spacing: 0) {
            SectionHeader("Recent interactions")
            RegardsCard {
                if viewModel.interactions.isEmpty {
                    Text("No interactions logged yet.")
                        .font(.footnote)
                        .foregroundStyle(RegardsDS.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(viewModel.interactions.enumerated()), id: \.element.id) { idx, entry in
                            AccessibilityAdaptiveLayout {
                                HStack(alignment: .top, spacing: 12) {
                                    interactionDate(entry.dateLabel, fixedWidth: 64)
                                    interactionDescription(entry.descriptionLabel)
                                    Spacer()
                                }
                            } accessibility: {
                                VStack(alignment: .leading, spacing: 4) {
                                    interactionDate(entry.dateLabel)
                                    interactionDescription(entry.descriptionLabel)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(interactionAccessibilityLabel(entry))
                            .accessibilityIdentifier("contact-detail.interaction-row")
                            if idx < viewModel.interactions.count - 1 {
                                Hair(inset: 16)
                            }
                        }
                    }
                }
            }
        }
    }

    // The label is derived on `InteractionEntry` so it can be asserted in unit
    // tests without instantiating the view.
    func interactionAccessibilityLabel(
        _ entry: ContactDetailViewModel.InteractionEntry
    ) -> String {
        entry.accessibilityLabel
    }

    func notesCard(contact: Contact) -> some View {
        VStack(spacing: 0) {
            SectionHeader("Notes · private to Regards")
            RegardsCard {
                Text(contact.notes.isEmpty ? "No notes yet." : contact.notes)
                    .font(.subheadline)
                    .italic(!contact.notes.isEmpty)
                    .foregroundStyle(contact.notes.isEmpty ? RegardsDS.muted : RegardsDS.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .lineSpacing(3)
            }
        }
    }

    func interactionDate(_ value: String, fixedWidth: CGFloat? = nil) -> some View {
        Text(value)
            .font(RegardsFont.mono(.footnote))
            .foregroundStyle(RegardsDS.muted)
            .frame(width: fixedWidth, alignment: .leading)
    }

    func interactionDescription(_ value: String) -> some View {
        Text(value)
            .font(.footnote)
            .foregroundStyle(RegardsDS.ink)
    }
}
