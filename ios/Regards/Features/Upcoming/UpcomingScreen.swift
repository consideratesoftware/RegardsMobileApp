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
    private let onTapContact: (UUID) -> Void
    private let onSwitchToOverdue: () -> Void

    public init(viewModel: UpcomingViewModel,
                accessibilityEffects: RowActionAccessibilityEffects,
                overdueCount: Int = 0,
                onTapContact: @escaping (UUID) -> Void = { _ in },
                onSwitchToOverdue: @escaping () -> Void = {},
                rowActionAnnouncer: RowActionAnnouncer) {
        self.viewModel = viewModel
        self.accessibilityEffects = accessibilityEffects
        self.overdueCount = overdueCount
        self.onTapContact = onTapContact
        self.onSwitchToOverdue = onSwitchToOverdue
        self._rowActionAnnouncer = State(initialValue: rowActionAnnouncer)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Next \(viewModel.horizonDays) days")
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
                            if newValue == .overdue { onSwitchToOverdue() }
                        }
                    ),
                    options: [
                        .init(id: .overdue,  label: "Overdue",  count: overdueCount),
                        .init(id: .upcoming, label: "Upcoming", count: viewModel.totalCount),
                    ]
                )
                .padding(.top, 18)

                Text("Get ahead of things — mark someone caught up before the reminder fires.")
                    .font(.footnote)
                    .foregroundStyle(RegardsDS.muted)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                listContent

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .navigationTitle("Upcoming")
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("screen.upcoming")
        // Initial load is owned by `RegardsTabRoot`; `.onAppear` reloads on
        // every subsequent appearance (a pop back from Contact Detail
        // included) — see sibling note in `OverdueScreen`.
        .onAppear {
            Task { await viewModel.load() }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView("Loading upcoming reminders")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        case .failed:
            loadError
        case .loaded where viewModel.groups.isEmpty:
            empty
        case .loaded:
            let transitionSources = viewModel.transitionSourceRowIDs
            ForEach(Array(viewModel.groups.enumerated()), id: \.offset) { _, group in
                SectionHeader(group.header)
                RegardsCard {
                    VStack(spacing: 0) {
                        ForEach(Array(group.rows.enumerated()), id: \.element.id) { idx, row in
                            UpcomingRow(
                                row: row,
                                ownsTransitionSource: transitionSources.contains(row.id),
                                onTap: { onTapContact(row.contactId) },
                                onMarkCaughtUp: {
                                    Task {
                                        let succeeded = await viewModel.markCaughtUp(contactId: row.contactId)
                                        if succeeded {
                                            announceRowAction("Marked \(row.name) caught up")
                                        }
                                    }
                                }
                            )
                            if idx < group.rows.count - 1 {
                                Hair(inset: 68)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Announces a row-removing action and lands focus on the subtitle
    /// (already updated to the new count by the time this fires) once the
    /// list has settled — the generation-guarded sequencing itself lives in
    /// `RowActionAnnouncer`, shared with `OverdueScreen`.
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
        .padding(.horizontal, 24)
        .padding(.top, 32)
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
        .padding(.horizontal, 24)
        .padding(.top, 32)
    }
}

struct UpcomingRow: View {
    let row: UpcomingRowState
    /// Only one row per contact may declare the zoom source; see
    /// `UpcomingViewModel.transitionSourceRowIDs`.
    let ownsTransitionSource: Bool
    let onTap: () -> Void
    let onMarkCaughtUp: () -> Void

    var body: some View {
        AccessibilityAdaptiveLayout {
            HStack(spacing: 12) {
                rowButton
                caughtUpButton
            }
        } accessibility: {
            VStack(alignment: .leading, spacing: 8) {
                rowButton
                caughtUpButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var rowButton: some View {
        Button(action: onTap) {
            AccessibilityAdaptiveLayout {
                HStack(spacing: 12) {
                    Avatar(name: row.name, size: 40)
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
                    Avatar(name: row.name, size: 40)
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double-tap to open contact detail.")
        // Stable identifier for UI tests that need to target a row
        // specifically (vs. nav-bar actions or segmented-control
        // buttons that also live on this screen).
        .accessibilityIdentifier("upcoming.row")
        .regardsContactTransitionSource(id: row.contactId, isActive: ownsTransitionSource)
    }

    private var caughtUpButton: some View {
        Button(action: onMarkCaughtUp) {
            Text("Caught up")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RegardsDS.accentInk)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(RegardsDS.accentSoft))
        .overlay(Capsule().stroke(RegardsDS.hair, lineWidth: 0.5))
        .accessibilityLabel("Mark \(row.name) caught up")
        .accessibilityHint("Removes this reminder from Upcoming.")
        .accessibilityIdentifier("upcoming.caught-up")
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

    private var occasion: some View {
        Text(row.occasionText ?? row.cadenceText ?? "")
            .font(.footnote)
            .foregroundStyle(RegardsDS.muted)
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
