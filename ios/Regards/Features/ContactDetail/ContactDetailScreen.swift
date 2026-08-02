import SwiftUI

public struct ContactDetailScreen: View {
    private struct EditRoute: Hashable {
        let contactId: UUID
    }

    let viewModel: ContactDetailViewModel
    private let onTapOpenChannel: () -> Void
    private let onTapMarkCaughtUp: () -> Void

    public init(viewModel: ContactDetailViewModel,
                onTapOpenChannel: @escaping () -> Void = {},
                onTapMarkCaughtUp: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.onTapOpenChannel = onTapOpenChannel
        self.onTapMarkCaughtUp = onTapMarkCaughtUp
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
        .accessibilityIdentifier("screen.contact-detail")
        .navigationDestination(for: EditRoute.self) { route in
            editContact(for: route.contactId)
        }
        .toolbar {
            if let contact = viewModel.contact {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: EditRoute(contactId: contact.id)) {
                        Text("Edit")
                            .foregroundStyle(RegardsDS.accentInk)
                    }
                }
            }
        }
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private func editContact(for contactId: UUID) -> some View {
        if let contact = viewModel.contact, contact.id == contactId {
            EditContactScreen(contact: contact)
        } else {
            ContentUnavailableView(
                "Contact unavailable",
                systemImage: "person.crop.circle.badge.questionmark"
            )
        }
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
        Button(action: onTapOpenChannel) {
            HStack(spacing: 10) {
                ChannelGlyph(channel: contact.preferredChannel, size: 20, color: .white)
                Text("Open \(contact.preferredChannel.displayName)")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            // `accentInk` so the white headline passes AA body contrast.
            .background(RegardsDS.accentInk, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(contact.preferredChannel.displayName) with \(contact.displayName)")
        .accessibilityHint("Opens in \(contact.preferredChannel.displayName) — no message prefill.")
    }

    private var secondaryActions: some View {
        HStack(spacing: 8) {
            secondaryButton("Caught up", action: onTapMarkCaughtUp)
            secondaryButton("Snooze 1 wk", action: {})
            secondaryButton("Log other", action: {})
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(RegardsDS.ink)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(RegardsDS.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RegardsDS.hair, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cards

    private func cadenceCard(contact: Contact) -> some View {
        VStack(spacing: 0) {
            SectionHeader("Cadence")
            RegardsCard {
                VStack(spacing: 0) {
                    detailRow(label: "Every", value: viewModel.cadenceLabel,
                              action: "Change")
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
                    Spacer()
                    Text("Change")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(RegardsDS.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
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
                            HStack(alignment: .top, spacing: 12) {
                                Text(entry.dateLabel)
                                    .font(RegardsFont.mono(.footnote))
                                    .foregroundStyle(RegardsDS.muted)
                                    .frame(width: 64, alignment: .leading)
                                Text(entry.descriptionLabel)
                                    .font(.footnote)
                                    .foregroundStyle(RegardsDS.ink)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            if idx < viewModel.interactions.count - 1 {
                                Hair(inset: 16)
                            }
                        }
                    }
                }
            }
        }
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

    // MARK: - Helpers

    private func detailRow(label: String,
                           value: String,
                           action: String? = nil,
                           isAccent: Bool = false,
                           isDanger: Bool = false) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.caption2)
                    .kerning(0.5)
                    .foregroundStyle(RegardsDS.muted)
                Text(value)
                    .font(.body.weight(isAccent ? .semibold : .medium))
                    .foregroundStyle(valueColor(isAccent: isAccent, isDanger: isDanger))
            }
            Spacer()
            // Stub label — Phase 1 wires each of these to a real editor. For
            // now we render muted so it doesn't look tap-affordable.
            if let action {
                Text(action)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RegardsDS.muted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func valueColor(isAccent: Bool, isDanger: Bool) -> Color {
        if isDanger { return RegardsDS.danger }
        if isAccent { return RegardsDS.accentInk }
        return RegardsDS.ink
    }

    private func nextReminderLabel(contact: Contact) -> String {
        // Phase 0 placeholder — PR3 wires a real engine; for now show "Today, 6:30 pm".
        "Today, 6:30 pm"
    }

    private var statusValue: String {
        let (days, overdue) = viewModel.overdueSummary
        return overdue ? "\(days) days overdue" : "on track"
    }
}
