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
                RegardsNavBar(
                    title: "Upcoming",
                    subtitle: "next \(viewModel.horizonDays) days",
                    rightAction: (text: "Horizon", handler: nil)
                )
                .padding(.top, 10)

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

                if viewModel.groups.isEmpty {
                    empty
                } else {
                    ForEach(Array(viewModel.groups.enumerated()), id: \.offset) { _, group in
                        SectionHeader(group.header)
                        RegardsCard {
                            VStack(spacing: 0) {
                                ForEach(Array(group.rows.enumerated()), id: \.element.id) { idx, row in
                                    UpcomingRow(row: row, onTap: { onTapContact(row.contactId) })
                                    if idx < group.rows.count - 1 {
                                        Hair(inset: 68)
                                    }
                                }
                            }
                        }
                    }
                }

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("screen.upcoming")
        // Load is owned by `RegardsTabRoot` — see sibling note in
        // `OverdueScreen`.
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("Nothing upcoming.")
                .font(RegardsFont.serifItalic(.title))
                .foregroundStyle(RegardsDS.ink)
            Text("Reminders for the next \(viewModel.horizonDays) days will show up here.")
                .font(.subheadline)
                .foregroundStyle(RegardsDS.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 60)
    }
}

struct UpcomingRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let row: UpcomingRowState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
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
                } else {
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
                }
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

    private var accessibilityLabel: String {
        let what = row.kind == .cadence
            ? (row.cadenceText ?? "")
            : String(describing: row.kind)
        return "\(row.name), \(what) at \(row.timeOfDayText)"
    }
}
