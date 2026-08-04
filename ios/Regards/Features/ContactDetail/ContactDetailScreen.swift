import SwiftUI

public struct ContactDetailScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var viewModel: ContactDetailViewModel
    @State private var previewContact: Contact?

    public init(viewModel: ContactDetailViewModel) {
        self._viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let c = viewModel.contact {
                    hero(contact: c)
                    primaryCTA(contact: c)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                    secondaryActions
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    cadenceCard(contact: c)
                    channelCard(contact: c)
                    interactionsCard
                    notesCard(contact: c)

                    Text("Notes stay on this device. Never written back to your address book.")
                        .font(.caption)
                        .foregroundStyle(RegardsDS.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                } else {
                    ProgressView().padding(.top, 100)
                }

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .regardsContactTransitionDestination(id: viewModel.contactID)
        .accessibilityIdentifier("screen.contact-detail")
        .navigationTitle("Contact")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $previewContact) { contact in
            EditContactScreen(contact: contact)
        }
        .toolbar {
            if viewModel.contact != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        previewContact = viewModel.contact
                    } label: {
                        Text("Edit")
                            .foregroundStyle(RegardsDS.accentInk)
                    }
                    .accessibilityIdentifier("contact-detail.edit")
                }
            }
        }
        .task { await viewModel.load() }
    }

    // MARK: - Sections

    private func hero(contact: Contact) -> some View {
        VStack(spacing: 12) {
            Avatar(name: contact.displayName, size: 88,
                   hasAccentRing: contact.priorityTier == .innerCircle)
                .padding(.top, 16)
            Text(contact.displayName)
                .font(.system(.title, weight: .bold))
                .foregroundStyle(RegardsDS.ink)
                .accessibilityAddTraits(.isHeader)
            Text(viewModel.priorityLabel)
                .font(RegardsFont.serifItalic(.body))
                .foregroundStyle(RegardsDS.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func primaryCTA(contact: Contact) -> some View {
        HStack(spacing: 10) {
            ChannelGlyph(channel: contact.preferredChannel, size: 20, color: RegardsDS.muted)
            Text("Open \(contact.preferredChannel.displayName)")
                .font(.headline)
                .foregroundStyle(RegardsDS.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 54)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 10 : 0)
        .background(RegardsDS.hairSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(RegardsDS.hair, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Open \(contact.preferredChannel.displayName), unavailable")
        .accessibilityIdentifier("contact-detail.open-channel-unavailable")
    }

    private var secondaryActions: some View {
        AccessibilityAdaptiveLayout {
            HStack(spacing: 8) {
                secondaryItems
            }
        } accessibility: {
            VStack(spacing: 8) {
                secondaryItems
            }
        }
    }

    @ViewBuilder
    private var secondaryItems: some View {
        secondaryStub("Caught up", identifier: "contact-detail.caught-up-unavailable")
        secondaryStub("Snooze 1 wk", identifier: "contact-detail.snooze-unavailable")
        secondaryStub("Log other", identifier: "contact-detail.log-other-unavailable")
    }

    private func secondaryStub(_ title: String, identifier: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(RegardsDS.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
            .background(RegardsDS.hairSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(RegardsDS.hair, lineWidth: 0.5))
            .accessibilityLabel("\(title), unavailable")
            .accessibilityIdentifier(identifier)
    }

    // MARK: - Cards

    private func cadenceCard(contact: Contact) -> some View {
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
                    detailRow(label: "Status", value: statusValue, isDanger: viewModel.overdueSummary.isOverdue)
                }
            }
        }
    }

    private func channelCard(contact: Contact) -> some View {
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

    private func channelSummary(contact: Contact) -> some View {
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

    static func channelSummaryAccessibilityLabel(contact: Contact) -> String {
        ContactValueAccessibility.label(
            contact.preferredChannel.displayName,
            displayedValue: contact.preferredChannelValue,
            channel: contact.preferredChannel,
            annotation: "preferred"
        )
    }

    private var interactionsCard: some View {
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

    private func interactionAccessibilityLabel(
        _ entry: ContactDetailViewModel.InteractionEntry
    ) -> String {
        let spokenDescription = entry.descriptionLabel.replacingOccurrences(
            of: " · ",
            with: ", "
        )
        return "\(entry.dateLabel), \(spokenDescription)"
    }

    private func notesCard(contact: Contact) -> some View {
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

    private func interactionDate(_ value: String, fixedWidth: CGFloat? = nil) -> some View {
        Text(value)
            .font(RegardsFont.mono(.footnote))
            .foregroundStyle(RegardsDS.muted)
            .frame(width: fixedWidth, alignment: .leading)
    }

    private func interactionDescription(_ value: String) -> some View {
        Text(value)
            .font(.footnote)
            .foregroundStyle(RegardsDS.ink)
    }
}

private extension ContactDetailScreen {

    // MARK: - Helpers

    func detailRow(label: String,
                   value: String,
                   action: String? = nil,
                   actionIdentifier: String? = nil,
                   isAccent: Bool = false,
                   isDanger: Bool = false) -> some View {
        AccessibilityAdaptiveLayout {
            HStack(spacing: 12) {
                detailValue(label: label, value: value, isAccent: isAccent, isDanger: isDanger)
                Spacer()
                stubAction(action, identifier: actionIdentifier)
            }
        } accessibility: {
            VStack(alignment: .leading, spacing: 8) {
                detailValue(label: label, value: value, isAccent: isAccent, isDanger: isDanger)
                stubAction(action, identifier: actionIdentifier)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    func detailValue(label: String,
                     value: String,
                     isAccent: Bool,
                     isDanger: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2)
                .kerning(0.5)
                .foregroundStyle(RegardsDS.muted)
            Text(value)
                .font(.body.weight(isAccent ? .semibold : .medium))
                .foregroundStyle(valueColor(isAccent: isAccent, isDanger: isDanger))
                .accessibilityIdentifier(
                    "contact-detail.detail-value-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
                )
        }
    }

    @ViewBuilder
    func stubAction(_ action: String?, identifier: String? = nil) -> some View {
        // TF-04/TF-08 wire these to real actions. Until then, muted text
        // accurately communicates that the labels are unavailable.
        if let action {
            Text(action)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(RegardsDS.muted)
                .accessibilityLabel("\(action), unavailable")
                .accessibilityIdentifier(identifier ?? "contact-detail.unavailable-action")
        }
    }

    func valueColor(isAccent: Bool, isDanger: Bool) -> Color {
        if isDanger { return RegardsDS.danger }
        if isAccent { return RegardsDS.accentInk }
        return RegardsDS.ink
    }

    func nextReminderLabel(contact: Contact) -> String {
        // TF-07 replaces this placeholder with the persisted next reminder.
        "Today, 6:30 pm"
    }

    var statusValue: String {
        let (days, overdue) = viewModel.overdueSummary
        return overdue ? "\(days) days overdue" : "on track"
    }
}
