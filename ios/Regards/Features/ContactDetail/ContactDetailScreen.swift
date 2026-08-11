import SwiftUI

public struct ContactDetailScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Not `private`: the card builders live in
    // `ContactDetailScreen+Cards.swift`, split out at SwiftLint's 500-line
    // file limit, and `private` is file-scoped.
    @State var viewModel: ContactDetailViewModel
    @State private var previewContact: Contact?
    @State private var showsLogOtherChannelPicker = false
    // Wrapped in `@State` via `init` — see `RowActionAnnouncer`'s doc comment for why.
    @State private var rowActionAnnouncer: RowActionAnnouncer
    // Focus target for all three row actions: the Cadence card's "Status"
    // value, mirroring `OverdueScreen`/`UpcomingScreen`'s subtitle. Content
    // plausibly changed (overdue → on track), and it survives every reload
    // `load()` can take — the hero/cadence card vanishes only on a total
    // contact-fetch failure, which none of these writes can cause.
    // Not `private` — see `viewModel` above; the Cards file binds to it.
    @AccessibilityFocusState var isStatusFocused: Bool
    // No default: a missed injection silently falling back to `.live` is
    // exactly the class of bug that shipped unannounced/unfocused row
    // actions to device — every construction site must say which it means.
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
        // See `LogOtherChannelSheet`'s doc comment: a `.sheet` we build
        // ourselves, replacing an earlier `confirmationDialog` that rendered
        // as a popover with no reachable Cancel control.
        .sheet(isPresented: $showsLogOtherChannelPicker) {
            LogOtherChannelSheet(
                onSelect: { channel in
                    showsLogOtherChannelPicker = false
                    Task {
                        let succeeded = await viewModel.logOther(channel: channel)
                        // `viewModel.contact?.displayName`: this sheet is outside `if let c =
                        // viewModel.contact` below. `?? "this contact"` covers a failed reload too.
                        let name = viewModel.contact?.displayName ?? "this contact"
                        if succeeded {
                            announceRowAction("Logged \(channel.displayName) with \(name)")
                        } else {
                            announceRowAction("Couldn't log \(channel.displayName) with \(name).")
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

// `internal`, not `private`: the card builders moved to
// `ContactDetailScreen+Cards.swift` at SwiftLint's 500-line file limit and
// call `detailRow`, `stubAction`, `nextReminderLabel`, and `valueColor`
// from there. `private` is file-scoped, so keeping it would mean either
// duplicating those helpers or threading them through as parameters.
extension ContactDetailScreen {

    // MARK: - Sections
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
                } else {
                    announceRowAction("Couldn't mark \(contact.displayName) caught up.")
                }
            }
        }
        .accessibilityHint("Logs an interaction now and updates status.")
        // Overdue/Upcoming gate a cadence row on `tracked && cadenceDays !=
        // nil`; an untracked/no-cadence contact has no `ScheduledReminder`.
        if contact.tracked, contact.cadenceDays != nil {
            secondaryAction("Snooze 1 wk", identifier: "contact-detail.snooze") {
                Task {
                    let succeeded = await viewModel.snooze()
                    // `movesFocus: false` on both branches — see
                    // `announceRowAction`'s doc comment for why Snooze never
                    // moves focus, success or failure.
                    if succeeded {
                        announceRowAction("Snoozed \(contact.displayName) 1 week", movesFocus: false)
                    } else {
                        announceRowAction("Couldn't snooze \(contact.displayName).", movesFocus: false)
                    }
                }
            }
            // "1 wk" reads as a literal abbreviation without this. No name,
            // unlike Overdue/Upcoming's "Snooze <name> 1 week": the name
            // distinguishes rows there, while this screen is about one
            // contact and its siblings are plain "Caught up"/"Log other".
            .accessibilityLabel("Snooze 1 week")
            .accessibilityHint("Pushes the next reminder out one week.")
        }
        secondaryAction("Log other", identifier: "contact-detail.log-other") {
            showsLogOtherChannelPicker = true
        }
        .accessibilityHint("Choose the channel you used to reach them.")
    }

    /// Announces a row action's outcome — success or failure, every call
    /// site above and the Log-other channel buttons below use this — and,
    /// when `movesFocus`, lands focus on the Cadence card's "Status" value;
    /// sequencing lives in `RowActionAnnouncer`, shared with
    /// `OverdueScreen`/`UpcomingScreen`.
    /// `private` (staged review round 8, nit) — every call site is inside
    /// this file, matching `OverdueScreen`/`UpcomingScreen`'s own
    /// `announceRowAction`; this one had drifted non-private with no caller
    /// outside this file to justify it, the one gap in an otherwise
    /// consistent trio that carries contact-name-bearing announcement text.
    ///
    /// `movesFocus` defaults to `true` for Caught up and Log other, both of
    /// which genuinely move `Contact.lastInteractedAt` — Status really has
    /// changed by the time focus lands there. Snooze passes `false`
    /// explicitly on both its success and failure branches (staged review
    /// round 9): Snooze never touches `lastInteractedAt` at all (decision
    /// #31), and this screen has no `ReminderRepository` of its own to
    /// reflect the pending reminder it just wrote (R56), so `overdueSummary`
    /// — the value Status reads — is byte-identical before and after either
    /// outcome. Before this fix, focus landed there anyway and VoiceOver
    /// read the same stale "N days overdue" straight after the
    /// announcement, as if it were new — nothing was removed on this
    /// screen the way a row disappearing from Overdue/Upcoming justifies
    /// the same move there, so the cursor never needed to drop in the
    /// first place. Skipping the move keeps the announcement as the only
    /// spoken confirmation, which is the one true thing here.
    private func announceRowAction(_ message: String, movesFocus: Bool = true) {
        rowActionAnnouncer.fire(message, effects: accessibilityEffects) {
            if movesFocus {
                isStatusFocused = true
            }
        }
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
        guard overdue else { return "on track" }
        // Singular "1 day overdue" (nit, staged review round 9's own
        // review, fixed round 10): newly reachable for a never-contacted
        // contact exactly 1 day past its cadence, since decision #29's
        // `?? createdAt` anchor (R8) made `days == 1` a real value here for
        // the first time — same `N == 1 ? singular : plural` pattern as
        // `Contact.relativeDescription`'s week/month/year branches.
        return days == 1 ? "1 day overdue" : "\(days) days overdue"
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
