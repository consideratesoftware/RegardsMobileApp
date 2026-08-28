import SwiftUI

/// Split out of `OverdueScreen.swift` (linter file-length limit) — no
/// behavior change, same type, same call site (`OverdueScreen.rowSection
/// (for:header:innerCircle:)`).
///
/// Owner decision, reversing R52 (staged review round 12): the row itself
/// is a single tap target again — Caught up / Snooze move to native
/// `.swipeActions`, and the three-way `contactButton` / `channelPill` /
/// `caughtUpButton` / `snoozeButton` split the row used to need is gone
/// with them. `ChannelGlyph` stays as a trailing decorative indicator, not
/// a separate control — see its own placement below.
struct OverdueRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let row: OverdueRowState
    let isInnerCircle: Bool
    let onTapContact: () -> Void
    let onMarkCaughtUp: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        // Tap opens a channel-action preview, not Contact Detail (owner
        // decision, round 12, superseding an earlier same-round decision
        // that kept tap on Contact Detail): Sid wants tap to eventually
        // perform the channel action itself, matching the Phone app's
        // Favorites tab — the interaction model is what matters now, wiring
        // it is TF-08's problem. `onTapContact` sets `channelPreviewRow`,
        // driving `.alert` on `OverdueScreen.body`. Contact Detail stays
        // reachable through the Contacts tab; no long-press fallback was
        // added here.
        Button(action: onTapContact) {
            AccessibilityAdaptiveLayout {
                HStack(spacing: 10) {
                    Avatar(name: row.name, size: 40, hasAccentRing: isInnerCircle, showsInitials: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(RegardsFont.rowTitle())
                            .foregroundStyle(RegardsDS.ink)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        metadataLine
                    }
                    Spacer(minLength: 8)
                    // Decorative only, not a separate control — tapping the
                    // row previews exactly what this glyph hints at (see
                    // `body`'s opening doc comment). `row.accessibilityLabel`
                    // below is the row's only spoken content; the preview
                    // alert speaks the channel by name when it appears.
                    ChannelGlyph(channel: row.channel, size: 18, color: RegardsDS.muted)
                }
            } accessibility: {
                HStack(alignment: .top, spacing: 10) {
                    Avatar(name: row.name, size: 40, hasAccentRing: isInnerCircle, showsInitials: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(RegardsFont.rowTitle())
                            .foregroundStyle(RegardsDS.ink)
                        metadataLine
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.accessibilityRepresentation`, not `.accessibilityElement
        // (children: .ignore)` (round 12 follow-up, empirically driven):
        // `.ignore` still left one leaked child in `List` — a duplicate of
        // the row itself, same label, `Button`-typed — confirmed directly
        // via a throwaway diagnostic (`row.children(matching: .any).count
        // == 1`, unaffected by modifier order, `.swipeActions` presence, or
        // wrapping in a plain `Group`). `List` composes a `Button`-rooted
        // row's cell in a way `.ignore`/`.combine` don't fully suppress —
        // see `UpcomingRow.body`'s matching doc comment, which found the
        // same mechanism leaking worse (4 children, including one already
        // marked `.accessibilityHidden(true)` at the source). Substituting
        // the accessibility subtree entirely, rather than trying to hide or
        // merge the real one, closes it — `row.children(matching: .any)
        // .count == 0`, confirmed by test
        // (`ScreensAccessibilityTests+RowActions.swift`'s
        // `assertRowIsOneOpaqueElement`).
        .accessibilityRepresentation {
            Button(action: onTapContact) {
                Text(row.accessibilityLabel)
            }
        }
        // Matches what tap now does (round 12) — see `body`'s opening doc
        // comment for the full reasoning.
        .accessibilityHint("Double-tap to preview the channel action.")
        // Stable identifier for UI tests that need to target a
        // contact-row tap specifically (vs. the nav-bar "All"
        // button or the segmented-control buttons that also
        // live on this screen).
        .accessibilityIdentifier("overdue.row")
        // No `.regardsContactTransitionSource` any more (round 12): that
        // modifier only matters as the *source* half of a matched-zoom
        // push to Contact Detail, and this row no longer pushes anywhere.
        // Swipe right → Caught up (leading edge, owner decision round 12).
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onMarkCaughtUp()
            } label: {
                Label("Caught up", systemImage: "checkmark")
            }
            .tint(RegardsDS.accentInk)
            .accessibilityLabel("Mark \(row.name) caught up")
            .accessibilityHint("Removes this contact from Overdue.")
        }
        // Swipe left → Snooze (trailing edge, owner decision round 12).
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                onSnooze()
            } label: {
                Label("Snooze", systemImage: "clock")
            }
            .tint(RegardsDS.muted)
            .accessibilityLabel("Snooze \(row.name) 1 week")
            .accessibilityHint("Removes this contact from Overdue for one week.")
        }
    }

    private var metadataLine: some View {
        Text(metadataString)
            .font(.footnote)
            .foregroundStyle(RegardsDS.muted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.tail)
    }

    /// Just how overdue, not cadence or last-contacted too (staged review
    /// round 11, Sid's words: "Just have name and how much overdue").
    /// Survives round 12's swipe-action redesign unchanged — correct
    /// regardless of how the actions fire. Matches `row.accessibilityLabel`
    /// exactly; see `Contact+Accessibility.swift`'s doc comment for the
    /// "labels mirror visible content" rule this satisfies.
    private var metadataString: String {
        "\(row.overdueDays)d overdue"
    }
}
