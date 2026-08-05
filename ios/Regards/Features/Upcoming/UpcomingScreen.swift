import SwiftUI

public struct UpcomingScreen: View {
    let viewModel: UpcomingViewModel
    @State private var segment: RegardsSegment = .upcoming
    private let overdueCount: Int
    private let onTapContact: (UUID) -> Void
    private let onSwitchToOverdue: () -> Void

    public init(viewModel: UpcomingViewModel,
                overdueCount: Int = 0,
                onTapContact: @escaping (UUID) -> Void = { _ in },
                onSwitchToOverdue: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.overdueCount = overdueCount
        self.onTapContact = onTapContact
        self.onSwitchToOverdue = onSwitchToOverdue
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
        // Load is owned by `RegardsTabRoot` — see sibling note in
        // `OverdueScreen`.
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
                                onTap: { onTapContact(row.contactId) }
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

    var body: some View {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
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
