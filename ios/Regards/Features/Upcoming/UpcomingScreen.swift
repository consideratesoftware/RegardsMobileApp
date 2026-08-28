import SwiftUI

public struct UpcomingScreen: View {
    let viewModel: UpcomingViewModel
    @State private var segment: RegardsSegment = .upcoming
    // Wrapped in `@State` via `init` below, not a plain default-initialized
    // property — see `RowActionAnnouncer`'s doc comment for why.
    @State private var rowActionAnnouncer: RowActionAnnouncer
    @AccessibilityFocusState private var isSubtitleFocused: Bool
    // No default — see `OverdueScreen`'s identical property for why.
    var accessibilityEffects: RowActionAccessibilityEffects
    private let overdueCount: Int
    private let onSwitchToOverdue: () -> Void
    // Row tap no longer pushes Contact Detail — see `OverdueScreen`'s
    // matching property for the full reasoning (owner decision, staged
    // review round 12).
    @State private var channelPreviewRow: UpcomingRowState?

    public init(viewModel: UpcomingViewModel,
                accessibilityEffects: RowActionAccessibilityEffects,
                overdueCount: Int = 0,
                onSwitchToOverdue: @escaping () -> Void = {},
                rowActionAnnouncer: RowActionAnnouncer) {
        self.viewModel = viewModel
        self.accessibilityEffects = accessibilityEffects
        self.overdueCount = overdueCount
        self.onSwitchToOverdue = onSwitchToOverdue
        self._rowActionAnnouncer = State(initialValue: rowActionAnnouncer)
    }

    // `List`, not `ScrollView` + `RegardsCard` — see `OverdueScreen`'s
    // matching doc comment (owner decision, reversing R52) for why.
    public var body: some View {
        List {
            header
            listContent
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RegardsDS.background.ignoresSafeArea())
        // See `OverdueScreen.body`'s matching `.safeAreaInset` for why this
        // is needed: the floating/minimizing tab bar does not reserve its
        // own footprint in `List`'s automatic bottom content inset, so the
        // last row renders underneath it without this.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 90)
        }
        .navigationTitle("Upcoming")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("screen.upcoming")
        // Initial load is owned by `RegardsTabRoot`; `.onAppear` reloads on
        // every subsequent appearance — see `OverdueScreen`'s matching
        // doc comment for why a tab switch, not a `NavigationStack` pop,
        // is the trigger since round 12.
        .onAppear {
            Task { await viewModel.load() }
        }
        // See `OverdueScreen.body`'s matching `.alert` for why this is a
        // native alert, not a custom sheet, and why it uses the
        // `isPresented:presenting:actions:message:` builder rather than
        // `item:content:` returning the older `Alert` struct.
        .alert(
            channelPreviewRow?.channel.displayName ?? "",
            isPresented: Binding(
                get: { channelPreviewRow != nil },
                set: { isPresented in
                    if !isPresented { channelPreviewRow = nil }
                }
            ),
            presenting: channelPreviewRow
        ) { _ in
            Button("Done") { channelPreviewRow = nil }
        } message: { row in
            Text(row.channel.tapPreviewMessage(for: row.name))
        }
    }

    @ViewBuilder
    private var header: some View {
        Text("Next \(viewModel.horizonDays) days")
            .font(.subheadline)
            .foregroundStyle(RegardsDS.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityFocused($isSubtitleFocused)
            .plainListRow(topPadding: 4)

        RegardsSegmentedControl(
            selection: Binding(
                get: { segment },
                set: { newValue in
                    segment = newValue
                    if newValue == .overdue { onSwitchToOverdue() }
                }
            ),
            options: [
                .init(id: .overdue, label: "Overdue", count: overdueCount),
                .init(id: .upcoming, label: "Upcoming", count: viewModel.totalCount)
            ]
        )
        .plainListRow(topPadding: 18)

        Text("Get ahead of things — mark someone caught up before the reminder fires.")
            .font(.footnote)
            .foregroundStyle(RegardsDS.muted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .plainListRow(topPadding: 8, bottomPadding: 14)
    }

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView("Loading upcoming reminders")
                .frame(maxWidth: .infinity)
                .plainListRow(topPadding: 40)
        case .failed:
            loadError
                .plainListRow(topPadding: 32)
        case .loaded where viewModel.groups.isEmpty:
            empty
                .plainListRow(topPadding: 32)
        case .loaded:
            ForEach(Array(viewModel.groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group.rows) { row in
                        UpcomingRow(
                            row: row,
                            onTap: { channelPreviewRow = row },
                            onMarkCaughtUp: {
                                Task {
                                    let succeeded = await viewModel.markCaughtUp(contactId: row.contactId)
                                    if succeeded {
                                        announceRowAction("Marked \(row.name) caught up")
                                    } else {
                                        announceRowAction("Couldn't mark \(row.name) caught up.")
                                    }
                                }
                            }
                        )
                        .listRowBackground(RegardsDS.surface)
                        .listRowSeparatorTint(RegardsDS.hair)
                    }
                } header: {
                    SectionHeader(group.header)
                        .listRowInsets(EdgeInsets())
                }
                .textCase(nil)
            }
        }
    }

    /// Announces a row action's outcome — success or failure, see the call
    /// site above — and lands focus on the subtitle (whose count reflects
    /// whichever actually happened) once the list has settled. The
    /// generation-guarded sequencing lives in `RowActionAnnouncer`, shared
    /// with `OverdueScreen`. A failure with no announcement would leave a
    /// VoiceOver user believing a silently reverted removal succeeded.
    private func announceRowAction(_ message: String) {
        rowActionAnnouncer.fire(message, effects: accessibilityEffects) {
            isSubtitleFocused = true
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing upcoming", systemImage: "calendar")
                .foregroundStyle(RegardsDS.ink)
        } description: {
            Text("Reminders for the next \(viewModel.horizonDays) days will show up here.")
        }
        .frame(maxWidth: .infinity)
    }

    private var loadError: some View {
        ContentUnavailableView {
            Label("Unable to load reminders", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Your reminder data is still on this device. Try loading it again.")
        } actions: {
            Button("Try Again") {
                Task { await viewModel.load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(RegardsDS.accentInk)
        }
        .frame(maxWidth: .infinity)
    }
}

struct UpcomingRow: View {
    let row: UpcomingRowState
    let onTap: () -> Void
    let onMarkCaughtUp: () -> Void

    var body: some View {
        // Tap opens a channel-action preview, not Contact Detail — see
        // `OverdueRow`'s matching doc comment for the full reasoning (owner
        // decision, staged review round 12). `onTap` sets the screen's
        // `channelPreviewRow`, which drives the `.alert` on
        // `UpcomingScreen.body`.
        Button(action: onTap) {
            AccessibilityAdaptiveLayout {
                HStack(spacing: 12) {
                    Avatar(name: row.name, size: 40, showsInitials: false)
                    VStack(alignment: .leading, spacing: 2) {
                        nameAndTag
                        occasion
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        time
                        ChannelGlyph(channel: row.channel, size: 14)
                    }
                }
            } accessibility: {
                HStack(alignment: .top, spacing: 12) {
                    Avatar(name: row.name, size: 40, showsInitials: false)
                    VStack(alignment: .leading, spacing: 4) {
                        nameAndTag
                        occasion
                        HStack(spacing: 6) {
                            time
                            ChannelGlyph(channel: row.channel, size: 14)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.accessibilityRepresentation`, not `.accessibilityElement
        // (children: .combine)` (round 12 follow-up, empirically driven):
        // `List` composes a `Button`-rooted row's cell in a way that leaks
        // its content as separately-queryable children regardless of
        // `.ignore` or `.combine` — confirmed directly (a throwaway
        // diagnostic enumerated 4 leaked children here: avatar initials,
        // name, time, and the channel glyph, the last of which is
        // `.accessibilityHidden(true)` in `ChannelGlyph` itself and still
        // leaked, so neither modifier was suppressing List's own row
        // composition). Substituting the accessibility subtree entirely,
        // rather than trying to hide or merge the real one, closes it —
        // see `OverdueRow.body`'s matching doc comment for the same fix
        // and proof there.
        .accessibilityRepresentation {
            Button(action: onTap) {
                Text(accessibilityLabel)
            }
        }
        // Matches what tap now does (round 12) — see the `Button` doc
        // comment above.
        .accessibilityHint("Double-tap to preview the channel action.")
        // Stable identifier for UI tests that need to target a row
        // specifically (vs. nav-bar actions or segmented-control
        // buttons that also live on this screen).
        .accessibilityIdentifier("upcoming.row")
        // No `.regardsContactTransitionSource` any more (round 12) — see
        // `OverdueRow`'s matching comment for why.
        // Swipe right → Caught up, cadence rows only (owner decision round
        // 12, matching the tap-target reasoning `OverdueRow` carries and
        // the pre-existing `row.kind == .cadence` gate this button already
        // had as an inline control): `markCaughtUp`/`SchedulingPass
        // .caughtUp` only ever clear a *cadence* reminder, so an occasion
        // row (birthday/anniversary/custom) has nothing true for this
        // action to do. No "swipe left" action here — unlike Overdue,
        // Upcoming has never had a Snooze control of its own (§10); adding
        // one now would be new functionality nobody asked for, not part of
        // this redesign.
        .modifier(CaughtUpSwipeAction(isEnabled: row.kind == .cadence, name: row.name, onMarkCaughtUp: onMarkCaughtUp))
    }

    private var nameAndTag: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(RegardsFont.rowTitle())
                .foregroundStyle(RegardsDS.ink)
            if row.kind == .birthday {
                RegardsTag("birthday", tone: .accent)
            } else if row.kind == .anniversary {
                RegardsTag("anniversary", tone: .accent)
            }
        }
    }

    /// Reversed, round 12 (Sid's call, not a flip-flop — recorded here so it
    /// reads as one): this doc comment used to argue the opposite, that
    /// unlike `OverdueRow.metadataString` this line carried exactly one fact
    /// and trimming it would leave cadence rows with nothing explaining why
    /// they're here. That reasoning held on the code alone. The round-12
    /// screenshot round (`ARCHITECTURE.md` R52) settled it differently: with
    /// `time` already on the row, a cadence row's name + cadence + time is
    /// the same "one fact too many" shape Overdue's old line had, just
    /// arrived at from a different starting point — cadence is the *when*
    /// restated, not a distinct *why* the way an occasion's name is. So the
    /// cadence half of this line is gone; a cadence row now shows only
    /// `nameAndTag` above it, name plus `time` below. Occasion rows
    /// (birthday/anniversary/custom) are unaffected: `occasionText` is the
    /// one fact a check-in row's `time` can't restate — it's not a second
    /// "when," it's the only "why" the row has — so it keeps rendering
    /// exactly as before. `UpcomingRowState.cadenceText` stays a populated
    /// field on the model (`CadenceDescriptor.describe(days:)` still runs);
    /// it's just no longer read here or by `accessibilityLabel` — see that
    /// property's own doc comment for the matching spoken-label change.
    @ViewBuilder
    private var occasion: some View {
        if let occasionText = row.occasionText {
            Text(occasionText)
                .font(.footnote)
                .foregroundStyle(RegardsDS.muted)
        }
    }

    private var time: some View {
        Text(row.timeOfDayText)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(RegardsDS.ink)
            .monospacedDigit()
    }

    // The label is derived on `UpcomingRowState` so it can be asserted in unit
    // tests without instantiating the view.
    private var accessibilityLabel: String { row.accessibilityLabel }
}

/// `.swipeActions` can't be applied conditionally with a plain `if` inside
/// a modifier chain the way a view can — this wraps the conditional so
/// `UpcomingRow.body` reads the same "chain of modifiers" shape as
/// `OverdueRow`'s unconditional one, rather than forking the whole chain
/// into two near-duplicate branches for cadence vs. occasion rows.
private struct CaughtUpSwipeAction: ViewModifier {
    let isEnabled: Bool
    let name: String
    let onMarkCaughtUp: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    onMarkCaughtUp()
                } label: {
                    Label("Caught up", systemImage: "checkmark")
                }
                .tint(RegardsDS.accentInk)
                .accessibilityLabel("Mark \(name) caught up")
                .accessibilityHint("Removes this reminder from Upcoming.")
            }
        } else {
            content
        }
    }
}
