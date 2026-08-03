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
    private let onSwitchToUpcoming: () -> Void

    public init(viewModel: OverdueViewModel,
                upcomingCount: Int = 7,
                onTapContact: @escaping (UUID) -> Void = { _ in },
                onSwitchToUpcoming: @escaping () -> Void = {}) {
        self.viewModel = viewModel
        self.upcomingCount = upcomingCount
        self.onTapContact = onTapContact
        self.onSwitchToUpcoming = onSwitchToUpcoming
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                RegardsNavBar(
                    title: "Overdue",
                    subtitle: subtitle,
                    rightAction: (text: "All", handler: nil)
                )
                .padding(.top, 10)

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

                if viewModel.rows.isEmpty {
                    emptyState
                } else {
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

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("screen.overdue")
        // No `.task { await viewModel.load() }` here — `RegardsTabRoot`
        // loads both tab VMs concurrently on root appear so the cross-tab
        // counters (Upcoming: N / Overdue: N) are populated before the
        // user sees either screen.
    }

    private var subtitle: String {
        switch viewModel.overdueCount {
        case 0: return "all caught up"
        case 1: return "1 person"
        default: return "\(viewModel.overdueCount) people"
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
        VStack(spacing: 8) {
            Text("All caught up.")
                .font(RegardsFont.serifItalic(.title))
                .foregroundStyle(RegardsDS.ink)
            Text("Nobody's overdue right now.")
                .font(.subheadline)
                .foregroundStyle(RegardsDS.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func rowStack(for rows: [OverdueRowState], innerCircle: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                OverdueRow(
                    row: row,
                    isInnerCircle: innerCircle,
                    onTapContact: { onTapContact(row.contactId) }
                )
                if idx < rows.count - 1 {
                    Hair(inset: 72)
                }
            }
        }
    }
}

struct OverdueRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let row: OverdueRowState
    let isInnerCircle: Bool
    let onTapContact: () -> Void

    var body: some View {
        AccessibilityAdaptiveLayout {
            HStack(spacing: 10) {
                contactButton
                channelPill
            }
        } accessibility: {
            VStack(alignment: .leading, spacing: 8) {
                contactButton
                channelPill
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
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(RegardsFont.rowTitle())
                            .foregroundStyle(RegardsDS.ink)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
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
    }

    private var metadataLine: some View {
        Text(metadataString)
            .font(.footnote)
            .foregroundStyle(RegardsDS.muted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
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
        HStack(spacing: 5) {
            ChannelGlyph(channel: row.channel, size: 13, color: RegardsDS.muted)
            Text(row.channelLabel)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(RegardsDS.muted)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Capsule().fill(RegardsDS.hairSoft))
        .overlay(Capsule().stroke(RegardsDS.hair, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.channelLabel), unavailable")
        .accessibilityIdentifier("overdue.channel-unavailable")
    }
}
