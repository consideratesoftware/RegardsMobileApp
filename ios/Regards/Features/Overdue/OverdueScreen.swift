import SwiftUI

public struct OverdueScreen: View {
    let viewModel: OverdueViewModel
    // View-local segment state + callback — same pattern as
    // `UpcomingScreen`. The tab root owns which actual `TabView` tab is
    // shown; this binding only drives the pill highlight and fires the
    // callback that asks the tab root to switch.
    @State private var segment: RegardsSegment = .overdue
    private let upcomingCount: Int
    private let onTapContact: (UUID) -> Void
    private let onTapChannel: (OverdueRowState) -> Void
    private let onSwitchToUpcoming: () -> Void

    public init(viewModel: OverdueViewModel,
                upcomingCount: Int = 7,
                onTapContact: @escaping (UUID) -> Void = { _ in },
                onTapChannel: @escaping (OverdueRowState) -> Void = { _ in },
                onSwitchToUpcoming: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.upcomingCount = upcomingCount
        self.onTapContact = onTapContact
        self.onTapChannel = onTapChannel
        self.onSwitchToUpcoming = onSwitchToUpcoming
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
        // user sees either screen.
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Send your regards —")
                .font(RegardsFont.serifItalic(.title2))
                .foregroundStyle(RegardsDS.ink)
            Text(viewModel.nextDigestLabel)
                .font(.subheadline)
                .foregroundStyle(RegardsDS.muted)
            Spacer(minLength: 0)
        }
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
                    onTapChannel: { onTapChannel(row) }
                )
                if idx < rows.count - 1 {
                    Hair(inset: 72)
                }
            }
        }
    }
}

struct OverdueRow: View {
    let row: OverdueRowState
    let isInnerCircle: Bool
    let onTapContact: () -> Void
    let onTapChannel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTapContact) {
                HStack(spacing: 10) {
                    Avatar(name: row.name, size: 40, hasAccentRing: isInnerCircle)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(row.name)
                                .font(RegardsFont.rowTitle())
                                .foregroundStyle(RegardsDS.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            if row.isVirtualMerged {
                                Text("merged")
                                    .font(.caption2)
                                    .foregroundStyle(RegardsDS.muted)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(RegardsDS.hairSoft))
                            }
                        }
                        metadataLine
                    }
                    Spacer(minLength: 8)
                }
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

            channelPill
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var metadataLine: some View {
        Text(metadataString)
            .font(.footnote)
            .foregroundStyle(RegardsDS.muted)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var metadataString: String {
        var parts: [String] = ["\(row.overdueDays)d overdue", row.cadenceText]
        if let last = row.lastInteractedText {
            parts.append("last \(last)")
        }
        return parts.joined(separator: " · ")
    }

    private var channelPill: some View {
        Button(action: onTapChannel) {
            HStack(spacing: 5) {
                ChannelGlyph(channel: row.channel, size: 13, color: .white)
                Text(row.channelLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            // `accentInk` bg for white body text — passes AA body contrast.
            // Lighter `accent` on "WhatsApp" at `.footnote.weight(.semibold)`
            // measures ~3.7:1 (small text, fails AA body).
            .background(Capsule().fill(RegardsDS.accentInk))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(row.channelLabel)")
        .accessibilityHint("Opens \(row.channelLabel) with \(row.name).")
    }
}
