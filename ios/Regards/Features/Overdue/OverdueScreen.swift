import SwiftUI

public struct OverdueScreen: View {
    let viewModel: OverdueViewModel
    // View-local segment state + callback — same pattern as
    // `UpcomingScreen`. The tab root owns which actual `TabView` tab is
    // shown; this binding only drives the pill highlight and fires the
    // callback that asks the tab root to switch.
    @State private var segment: RegardsSegment = .overdue
    // Wrapped in `@State` via `init` below, not a plain default-initialized
    // property — see `RowActionAnnouncer`'s doc comment for why.
    @State private var rowActionAnnouncer: RowActionAnnouncer
    @AccessibilityFocusState private var isSubtitleFocused: Bool
    // No default: a missed injection silently falling back to `.live` here
    // is exactly the class of bug that shipped unannounced/unfocused row
    // actions to device — every construction site must say which effects it
    // means, including production's own factory.
    var accessibilityEffects: RowActionAccessibilityEffects
    private let upcomingCount: Int
    private let onTapContact: (UUID) -> Void
    private let onSwitchToUpcoming: () -> Void

    public init(viewModel: OverdueViewModel,
                accessibilityEffects: RowActionAccessibilityEffects,
                upcomingCount: Int = 7,
                onTapContact: @escaping (UUID) -> Void = { _ in },
                onSwitchToUpcoming: @escaping () -> Void = {},
                rowActionAnnouncer: RowActionAnnouncer) {
        self.viewModel = viewModel
        self.accessibilityEffects = accessibilityEffects
        self.upcomingCount = upcomingCount
        self.onTapContact = onTapContact
        self.onSwitchToUpcoming = onSwitchToUpcoming
        self._rowActionAnnouncer = State(initialValue: rowActionAnnouncer)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(RegardsDS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .accessibilityFocused($isSubtitleFocused)

                RegardsSegmentedControl(
                    selection: Binding(
                        get: { segment },
                        set: { newValue in
                            segment = newValue
                            if newValue == .upcoming { onSwitchToUpcoming() }
                        }
                    ),
                    options: [
                        .init(id: .overdue,  label: "Overdue",  count: viewModel.overdueCount),
                        .init(id: .upcoming, label: "Upcoming", count: upcomingCount),
                    ]
                )
                .padding(.top, 18)

                digestRow
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                listContent

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .navigationTitle("Overdue")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("screen.overdue")
        // No `.task { await viewModel.load() }` here — `RegardsTabRoot`
        // loads both tab VMs concurrently on root appear so the cross-tab
        // counters (Upcoming: N / Overdue: N) are populated before the
        // user sees either screen. `.onAppear` below still reloads on every
        // subsequent appearance (a `NavigationStack` pop back from Contact
        // Detail counts), which is `load()`'s only route to noticing a
        // Contact Detail Snooze: `ReminderRepository` writes have no
        // `observeTracked()`-style push yet (that pipeline is TF-07/R10), so
        // without this, a session that snoozes from Detail and returns here
        // would keep showing the contact for the rest of the session.
        .onAppear {
            Task { await viewModel.load() }
        }
    }

    private var subtitle: String {
        guard viewModel.loadState == .loaded else {
            return viewModel.loadState == .loading ? "Loading…" : "Unavailable"
        }
        switch viewModel.overdueCount {
        case 0: return "all caught up"
        case 1: return "1 person"
        default: return "\(viewModel.overdueCount) people"
        }
    }

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView("Loading overdue contacts")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        case .failed:
            loadError
        case .loaded where viewModel.rows.isEmpty:
            emptyState
        case .loaded:
            if !viewModel.innerCircleRows.isEmpty {
                SectionHeader("Inner circle · overdue")
                RegardsCard { rowStack(for: viewModel.innerCircleRows, innerCircle: true) }
            }
            if !viewModel.closeFriendRows.isEmpty {
                SectionHeader("Close friends · overdue")
                RegardsCard { rowStack(for: viewModel.closeFriendRows) }
            }
            if !viewModel.otherRows.isEmpty {
                SectionHeader("Others · overdue")
                RegardsCard { rowStack(for: viewModel.otherRows) }
            }

            Text("Quiet until 6:00 pm. Reminders stay inside your chosen windows.")
                .font(.footnote)
                .foregroundStyle(RegardsDS.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 22)
        }
    }

    private var digestRow: some View {
        AccessibilityAdaptiveLayout {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                digestLead
                digestTime
                Spacer(minLength: 0)
            }
        } accessibility: {
            VStack(alignment: .leading, spacing: 2) {
                digestLead
                digestTime
            }
        }
    }

    private var digestLead: some View {
        Text("Send your regards —")
            .font(RegardsFont.serifItalic(.title2))
            .foregroundStyle(RegardsDS.ink)
            .accessibilityIdentifier("overdue.digest-lead")
    }

    private var digestTime: some View {
        Text(viewModel.nextDigestLabel)
            .font(.subheadline)
            .foregroundStyle(RegardsDS.muted)
            .accessibilityIdentifier("overdue.digest-time")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("All caught up", systemImage: "checkmark.circle")
                .foregroundStyle(RegardsDS.ink)
        } description: {
            Text("Nobody's overdue right now.")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    private var loadError: some View {
        ContentUnavailableView {
            Label("Unable to load overdue contacts", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Your contacts are still on this device. Try loading them again.")
        } actions: {
            Button("Try Again") {
                Task { await viewModel.load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(RegardsDS.accentInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    @ViewBuilder
    private func rowStack(for rows: [OverdueRowState], innerCircle: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                OverdueRow(
                    row: row,
                    isInnerCircle: innerCircle,
                    onTapContact: { onTapContact(row.contactId) },
                    onMarkCaughtUp: {
                        Task {
                            let succeeded = await viewModel.markCaughtUp(contactId: row.contactId)
                            if succeeded {
                                announceRowAction("Marked \(row.name) caught up")
                            } else {
                                announceRowAction("Couldn't mark \(row.name) caught up. Still overdue.")
                            }
                        }
                    },
                    onSnooze: {
                        Task {
                            let succeeded = await viewModel.snooze(contactId: row.contactId)
                            if succeeded {
                                announceRowAction("Snoozed \(row.name) 1 week")
                            } else {
                                announceRowAction("Couldn't snooze \(row.name). Still overdue.")
                            }
                        }
                    }
                )
                if idx < rows.count - 1 {
                    Hair(inset: 72)
                }
            }
        }
    }

    /// Announces a row action's outcome — success or failure, both call
    /// sites above use this — and lands focus on the subtitle (whose count
    /// reflects whichever actually happened by the time this fires) once the
    /// list has settled. The generation-guarded sequencing itself lives in
    /// `RowActionAnnouncer`, shared with `UpcomingScreen`. A failure with no
    /// announcement at all would leave a VoiceOver user believing a silently
    /// reverted optimistic removal succeeded.
    private func announceRowAction(_ message: String) {
        rowActionAnnouncer.fire(message, effects: accessibilityEffects) {
            isSubtitleFocused = true
        }
    }
}

struct OverdueRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // Scales the Caught up / Snooze glyphs the same way `ChannelGlyph`
    // scales its own icon (staged review round 11) — see that type's doc
    // comment for why `@ScaledMetric` over a fixed point size.
    @ScaledMetric(relativeTo: .body) private var actionIconSize: CGFloat = 18

    let row: OverdueRowState
    let isInnerCircle: Bool
    let onTapContact: () -> Void
    let onMarkCaughtUp: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        AccessibilityAdaptiveLayout {
            HStack(spacing: 10) {
                contactButton
                channelPill
                caughtUpButton
                snoozeButton
            }
        } accessibility: {
            VStack(alignment: .leading, spacing: 8) {
                contactButton
                channelPill
                caughtUpButton
                snoozeButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var contactButton: some View {
        Button(action: onTapContact) {
            HStack(spacing: 10) {
                Avatar(name: row.name, size: 40, hasAccentRing: isInnerCircle)
                VStack(alignment: .leading, spacing: 2) {
                    // No merged-chip branch here (round 11) — see
                    // `OverdueRowState`'s own doc comment for why it was
                    // removed rather than kept: it competed directly with
                    // this Text for width.
                    Text(row.name)
                        .font(RegardsFont.rowTitle())
                        .foregroundStyle(RegardsDS.ink)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .minimumScaleFactor(0.85)
                    metadataLine
                }
                Spacer(minLength: 8)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityHint("Double-tap to open contact detail.")
        // Stable identifier for UI tests that need to target a
        // contact-row tap specifically (vs. the nav-bar "All"
        // button or the segmented-control buttons that also
        // live on this screen).
        .accessibilityIdentifier("overdue.row")
        .regardsContactTransitionSource(id: row.contactId)
    }

    private var metadataLine: some View {
        Text(metadataString)
            .font(.footnote)
            .foregroundStyle(RegardsDS.muted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.tail)
    }

    /// Just how overdue, not cadence or last-contacted too (staged review
    /// round 11, Sid's words: "Just have name and how much overdue"). Now
    /// matches `row.accessibilityLabel` exactly — an earlier pass in this
    /// same round kept a fuller spoken label ("every N weeks, last
    /// contacted X ago") while trimming only this visible line, but that
    /// asymmetry was overruled by a standing principle: a label mirrors
    /// what the UI shows, and a departure needs a written reason at the
    /// site (`ios/docs/accessibility.md`). Cadence and last-contacted had
    /// no such reason, so both are gone from the label too, not just here.
    private var metadataString: String {
        "\(row.overdueDays)d overdue"
    }

    /// Icon-only, staged review round 11: the visible "Wh…"/"Sig…" text this
    /// pill used to carry is exactly what a screenshot on device caught
    /// truncating the contact name next to it — three fixed-width text
    /// pills always claimed their own intrinsic width first, leaving
    /// `contactButton` (the row's only flexible child, `Spacer` and all) to
    /// absorb the entire shortfall down to a single letter, at every
    /// Dynamic Type size, not just large ones (confirmed by measuring
    /// `contactButton`'s actual rendered width: ~77pt at both the smallest
    /// content size and the default one). Dropping the visible text here
    /// reclaims that width for the name instead of dividing the shortfall
    /// differently. The accessibility label is untouched — `channelLabel`
    /// comes from `Channel.displayName`, never from `ChannelGlyph`'s own
    /// (now-shared) SF Symbol, so "WhatsApp"/"Signal"/… still speaks in
    /// full even though several channels now render the same glyph.
    ///
    /// Deliberate exception to `ios/docs/accessibility.md`'s "labels mirror
    /// visible content" rule, not an oversight: the glyph itself no longer
    /// visually distinguishes between the 8+ channels sharing the bubble
    /// symbol, so the label has to carry the disambiguating information the
    /// icon alone can't. Do not simplify this to something generic like
    /// "Message, unavailable" for consistency with what's on screen — that
    /// would leave VoiceOver worse-informed than a sighted user, exactly
    /// what the rule exists to prevent.
    private var channelPill: some View {
        ChannelGlyph(channel: row.channel, size: 18, color: RegardsDS.muted)
            .frame(minWidth: 44, minHeight: 44)
            .background(Circle().fill(RegardsDS.hairSoft))
            .overlay(Circle().stroke(RegardsDS.hair, lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.channelLabel), unavailable")
            .accessibilityIdentifier("overdue.channel-unavailable")
    }

    /// Icon-only (round 11) — see `channelPill`'s doc comment for why.
    /// `minWidth`/`minHeight`, not just `minHeight` as the text pill had:
    /// a text pill's own horizontal padding kept it naturally ≥44pt wide,
    /// but an icon alone has no such built-in width, so the 44×44 minimum
    /// tap target needs to be stated on both axes explicitly.
    ///
    /// The label is also a deliberate exception to "labels mirror visible
    /// content" (`ios/docs/accessibility.md`), but for a different reason
    /// than `channelPill`'s: there is no visible text at all here to
    /// mirror, just a checkmark glyph. "Mark <name> caught up" names the
    /// action the control performs rather than describing what's on
    /// screen, which is the correct read of the rule for an unlabelled
    /// icon button, not a departure from it.
    private var caughtUpButton: some View {
        Button(action: onMarkCaughtUp) {
            Image(systemName: "checkmark")
                .font(.system(size: actionIconSize * 0.8, weight: .semibold))
                .foregroundStyle(RegardsDS.accentInk)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(RegardsDS.accentSoft))
        .overlay(Circle().stroke(RegardsDS.hair, lineWidth: 0.5))
        .accessibilityLabel("Mark \(row.name) caught up")
        .accessibilityHint("Removes this contact from Overdue.")
        .accessibilityIdentifier("overdue.caught-up")
    }

    /// Icon-only (round 11) — see `channelPill`'s doc comment for why. A
    /// clock face, not a bell or "zzz": distinct at a glance from
    /// `caughtUpButton`'s checkmark, and reads as "push this out," not
    /// "mute this," matching what the action actually does (decision #31:
    /// pushes the cadence reminder 7 days out, logs nothing).
    ///
    /// Same label exception as `caughtUpButton`, same reason: nothing
    /// visible to mirror, so "Snooze <name> 1 week" names the action
    /// instead.
    private var snoozeButton: some View {
        Button(action: onSnooze) {
            Image(systemName: "clock")
                .font(.system(size: actionIconSize * 0.8, weight: .semibold))
                .foregroundStyle(RegardsDS.muted)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(RegardsDS.hairSoft))
        .overlay(Circle().stroke(RegardsDS.hair, lineWidth: 0.5))
        .accessibilityLabel("Snooze \(row.name) 1 week")
        .accessibilityHint("Removes this contact from Overdue for one week.")
        .accessibilityIdentifier("overdue.snooze")
    }
}
