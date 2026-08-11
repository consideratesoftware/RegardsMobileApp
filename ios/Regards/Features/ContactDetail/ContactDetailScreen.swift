import SwiftUI

public struct ContactDetailScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var viewModel: ContactDetailViewModel
    @State private var previewContact: Contact?
    @State private var showsLogOtherChannelPicker = false
    // Wrapped in `@State` via `init` — see `RowActionAnnouncer`'s doc comment for why.
    @State private var rowActionAnnouncer: RowActionAnnouncer
    // Focus target for all three row actions: the Cadence card's "Status"
    // value, mirroring `OverdueScreen`/`UpcomingScreen`'s subtitle. Content
    // plausibly changed (overdue → on track), and it survives every reload
    // `load()` can take — the hero/cadence card only vanishes on a total
    // contact-fetch failure, which none of these writes can cause.
    @AccessibilityFocusState private var isStatusFocused: Bool
    // No default: a missed injection silently falling back to `.live` here
    // is exactly the class of bug that shipped unannounced/unfocused row
    // actions to device — every construction site must say which effects it
    // means, including production's own factory.
    var accessibilityEffects: RowActionAccessibilityEffects

    public init(
        viewModel: ContactDetailViewModel,
        accessibilityEffects: RowActionAccessibilityEffects,
        rowActionAnnouncer: RowActionAnnouncer
    ) {
        self._viewModel = State(initialValue: viewModel)
        self.accessibilityEffects = accessibilityEffects
        self._rowActionAnnouncer = State(initialValue: rowActionAnnouncer)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let c = viewModel.contact {
                    hero(contact: c)
                    primaryCTA(contact: c)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                    secondaryActions(contact: c)
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
        // See `LogOtherChannelSheet`'s doc comment: this used to be a
        // `confirmationDialog`, which rendered as a popover with no reachable
        // Cancel control on the OS this shipped against. A `.sheet` we build
        // ourselves removes that dependency entirely.
        .sheet(isPresented: $showsLogOtherChannelPicker) {
            LogOtherChannelSheet(
                onSelect: { channel in
                    showsLogOtherChannelPicker = false
                    Task {
                        let succeeded = await viewModel.logOther(channel: channel)
                        // `viewModel.contact?.displayName`, not a captured
                        // local: this sheet is declared outside the
                        // `if let c = viewModel.contact` scope below (it has
                        // to stay presentable even mid-reload), so there is
                        // no `contact` local here to close over.
                        if succeeded, let name = viewModel.contact?.displayName {
                            announceRowAction("Logged \(channel.displayName) with \(name)")
                        }
                    }
                },
                onCancel: { showsLogOtherChannelPicker = false }
            )
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
}

extension ContactDetailScreen {
    // Not `private`: `ContactAccessibilityTests` (another file) calls this
    // directly, and a `private extension` isn't visible outside its file.
    static func channelSummaryAccessibilityLabel(contact: Contact) -> String {
        ContactValueAccessibility.label(
            contact.preferredChannel.displayName,
            displayedValue: contact.preferredChannelValue,
            channel: contact.preferredChannel,
            annotation: "preferred"
        )
    }
}

private extension ContactDetailScreen {

    // MARK: - Sections
    //
    // Moved out of the struct body for SwiftLint's type_body_length — a
    // `private extension` in the same file has the same visibility as a
    // `private` struct member, so this is a pure move.

    func hero(contact: Contact) -> some View {
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

    func primaryCTA(contact: Contact) -> some View {
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

    func secondaryActions(contact: Contact) -> some View {
        AccessibilityAdaptiveLayout {
            HStack(spacing: 8) {
                secondaryItems(contact: contact)
            }
        } accessibility: {
            VStack(spacing: 8) {
                secondaryItems(contact: contact)
            }
        }
    }

    @ViewBuilder
    func secondaryItems(contact: Contact) -> some View {
        secondaryAction("Caught up", identifier: "contact-detail.caught-up") {
            Task {
                let succeeded = await viewModel.markCaughtUp()
                if succeeded {
                    announceRowAction("Marked \(contact.displayName) caught up")
                }
            }
        }
        .accessibilityHint("Logs an interaction now and updates status.")
        // Overdue/Upcoming gate a cadence row on `tracked && cadenceDays !=
        // nil`; an untracked/no-cadence contact has no `ScheduledReminder`
        // either list reads, so Snooze would write an inert row otherwise.
        if contact.tracked, contact.cadenceDays != nil {
            secondaryAction("Snooze 1 wk", identifier: "contact-detail.snooze") {
                Task {
                    let succeeded = await viewModel.snooze()
                    if succeeded {
                        announceRowAction("Snoozed \(contact.displayName) 1 week")
                    }
                }
            }
            // "1 wk" reads as a literal abbreviation without this. No
            // contact name, unlike Overdue/Upcoming's "Snooze <name> 1
            // week": there the name distinguishes rows, while this screen
            // is about one contact and its siblings are plain "Caught up"
            // and "Log other".
            .accessibilityLabel("Snooze 1 week")
            .accessibilityHint("Pushes the next reminder out one week.")
        }
        secondaryAction("Log other", identifier: "contact-detail.log-other") {
            showsLogOtherChannelPicker = true
        }
        .accessibilityHint("Choose the channel you used to reach them.")
    }

    /// Announces a row action's result and lands focus on the Cadence
    /// card's "Status" value — sequencing lives in `RowActionAnnouncer`,
    /// shared with `OverdueScreen`/`UpcomingScreen`. Also called from Log
    /// other's channel buttons below: choosing a channel is the success signal.
    func announceRowAction(_ message: String) {
        rowActionAnnouncer.fire(message, effects: accessibilityEffects) {
            isStatusFocused = true
        }
    }

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

    // MARK: - Helpers

    func secondaryAction(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(RegardsDS.accentInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
                .background(RegardsDS.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(RegardsDS.hair, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    func detailRow(label: String,
                   value: String,
                   action: String? = nil,
                   actionIdentifier: String? = nil,
                   isAccent: Bool = false,
                   isDanger: Bool = false,
                   valueFocus: AccessibilityFocusState<Bool>.Binding? = nil) -> some View {
        AccessibilityAdaptiveLayout {
            HStack(spacing: 12) {
                detailValue(label: label, value: value, isAccent: isAccent, isDanger: isDanger, valueFocus: valueFocus)
                Spacer()
                stubAction(action, identifier: actionIdentifier)
            }
        } accessibility: {
            VStack(alignment: .leading, spacing: 8) {
                detailValue(label: label, value: value, isAccent: isAccent, isDanger: isDanger, valueFocus: valueFocus)
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
                     isDanger: Bool,
                     valueFocus: AccessibilityFocusState<Bool>.Binding? = nil) -> some View {
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
                // Optional, not unconditional: only the "Status" row (the
                // one call site that passes `valueFocus`) is this screen's
                // row-action focus target — see `ContactDetailScreen`'s
                // `isStatusFocused` doc comment for why that row specifically.
                .modifier(OptionalAccessibilityFocus(focus: valueFocus))
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

/// `.accessibilityFocused(_:)` takes a concrete, non-optional
/// `AccessibilityFocusState<Bool>.Binding` — this lets `detailValue` accept
/// one only for the single call site (Contact Detail's "Status" row) that
/// needs to be a row-action focus target, without every other `detailRow`
/// call threading through a throwaway binding of its own.
private struct OptionalAccessibilityFocus: ViewModifier {
    let focus: AccessibilityFocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let focus {
            content.accessibilityFocused(focus)
        } else {
            content
        }
    }
}
