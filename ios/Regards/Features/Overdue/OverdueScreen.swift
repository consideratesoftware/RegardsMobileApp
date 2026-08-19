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
    private let onSwitchToUpcoming: () -> Void
    // Row tap no longer pushes Contact Detail (round 12) — it shows a
    // dismissable preview of the channel action pending TF-08. See
    // `OverdueRow.body`'s doc comment and `ARCHITECTURE.md` §10/R52.
    @State private var channelPreviewRow: OverdueRowState?

    public init(viewModel: OverdueViewModel,
                accessibilityEffects: RowActionAccessibilityEffects,
                upcomingCount: Int = 7,
                onSwitchToUpcoming: @escaping () -> Void = {},
                rowActionAnnouncer: RowActionAnnouncer) {
        self.viewModel = viewModel
        self.accessibilityEffects = accessibilityEffects
        self.upcomingCount = upcomingCount
        self.onSwitchToUpcoming = onSwitchToUpcoming
        self._rowActionAnnouncer = State(initialValue: rowActionAnnouncer)
    }

    // `List`, not `ScrollView` + `RegardsCard` (owner decision, reversing
    // R52 before anything shipped — see `ARCHITECTURE.md`'s R52 register
    // entry): Caught up / Snooze move from per-row buttons to native swipe
    // actions, and `.swipeActions` only functions inside `List` — a custom
    // gesture would need `.accessibilityAction(named:)` wired and kept in
    // sync by hand forever, exactly the cost a real `List` avoids for free
    // via the VoiceOver rotor. The header content above the sectioned rows
    // (subtitle, segmented control, digest row) rides along as plain,
    // separator-hidden, clear-background rows so it reads the same as it
    // did outside a list — see each one's own modifiers below.
    public var body: some View {
        List {
            header
            listContent
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(RegardsDS.background.ignoresSafeArea())
        // The old `ScrollView` carried a trailing `Color.clear.frame(height:
        // 40)` for this; `List` needs the same clearance explicitly (round
        // 12 follow-up) since the floating/minimizing tab bar doesn't
        // reserve its own footprint in `List`'s automatic bottom inset —
        // without this, the last row and the quiet-hours footer render
        // underneath it. Verified by screenshot at the bottom of the
        // scroll, not by reasoning about the number; see `ARCHITECTURE.md`
        // §10.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 90)
        }
        .navigationTitle("Overdue")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("screen.overdue")
        // No `.task { await viewModel.load() }` here — `RegardsTabRoot`
        // loads both tab VMs concurrently on root appear so the cross-tab
        // counters are populated before the user sees either screen.
        // `.onAppear` is `load()`'s only route to noticing a later Contact
        // Detail Snooze (`ReminderRepository` writes have no
        // `observeTracked()`-style push yet, TF-07/R10). Round 12 removed
        // this screen's own push to Contact Detail, so a `NavigationStack`
        // pop is no longer the trigger — confirmed by manual check that
        // `.onAppear` still fires on a plain tab switch back from Contacts,
        // the only route left, or a session that snoozes there and switches
        // back would keep showing the contact regardless.
        .onAppear {
            Task { await viewModel.load() }
        }
        // The channel-action preview (round 12) — a native `.alert`, not a
        // custom sheet: `LogOtherChannelSheet`'s own history is the reason
        // (see its doc comment) — a `confirmationDialog`/popover rendered
        // translucent with a dismissal region VoiceOver couldn't reach.
        // `.alert` has neither failure mode; its buttons are always in the
        // accessibility tree, on every OS this ships against, with no
        // presentation styling decision for a future review to get wrong.
        //
        // `isPresented:presenting:actions:message:`, not `item:content:`
        // returning the older `Alert` struct — a legitimate modernization
        // on its own, tried in round 12 as a candidate fix for a live
        // "Potentially inaccessible text" `.elementDetection` finding
        // while this alert is open (3 issues, every time). It did not fix
        // it — the finding is unresolved, not this API choice's fault; see
        // `ios/docs/accessibility.md`'s "Known system-UI audit
        // interruption" for the full investigation and
        // `ScreensAccessibilityTests+PresentedSurfaces.swift`'s matching
        // test doc comment.
        .alert(
            channelPreviewRow?.channelLabel ?? "",
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
        Text(subtitle)
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
                    if newValue == .upcoming { onSwitchToUpcoming() }
                }
            ),
            options: [
                .init(id: .overdue, label: "Overdue", count: viewModel.overdueCount),
                .init(id: .upcoming, label: "Upcoming", count: upcomingCount)
            ]
        )
        .plainListRow(topPadding: 18)

        digestRow
            .plainListRow(topPadding: 8, bottomPadding: 16)
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
                .plainListRow(topPadding: 40)
        case .failed:
            loadError
                .plainListRow(topPadding: 32)
        case .loaded where viewModel.rows.isEmpty:
            emptyState
                .plainListRow(topPadding: 32)
        case .loaded:
            if !viewModel.innerCircleRows.isEmpty {
                rowSection(for: viewModel.innerCircleRows, header: "Inner circle · overdue", innerCircle: true)
            }
            if !viewModel.closeFriendRows.isEmpty {
                rowSection(for: viewModel.closeFriendRows, header: "Close friends · overdue")
            }
            if !viewModel.otherRows.isEmpty {
                rowSection(for: viewModel.otherRows, header: "Others · overdue")
            }

            Text("Quiet until 6:00 pm. Reminders stay inside your chosen windows.")
                .font(.footnote)
                .foregroundStyle(RegardsDS.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .plainListRow(topPadding: 22)
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
    }

    /// One `Section` per priority tier. `SectionHeader` (the app's own
    /// uppercase-muted-caption primitive) is passed straight through as the
    /// `Section`'s header content rather than a plain `Text` — `.insetGrouped`
    /// would style a plain `Text` close to this already, but reusing the
    /// exact same primitive both screens already share keeps one definition
    /// of "what a section caption looks like," not two that could drift.
    @ViewBuilder
    private func rowSection(for rows: [OverdueRowState], header: String, innerCircle: Bool = false) -> some View {
        Section {
            ForEach(rows) { row in
                OverdueRow(
                    row: row,
                    isInnerCircle: innerCircle,
                    onTapContact: { channelPreviewRow = row },
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
                .listRowBackground(RegardsDS.surface)
                .listRowSeparatorTint(RegardsDS.hair)
            }
        } header: {
            SectionHeader(header)
                .listRowInsets(EdgeInsets())
        }
        .textCase(nil)
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
