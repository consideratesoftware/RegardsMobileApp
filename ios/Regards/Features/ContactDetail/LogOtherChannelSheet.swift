import SwiftUI

/// Contact Detail's "Log other channel" picker. A `.sheet` we build and
/// control ourselves, not a system `confirmationDialog` — see
/// `ContactDetailScreen`'s `.sheet` call site for why: `confirmationDialog`
/// rendered as an anchored, translucent popover on the OS this shipped
/// against, with no Cancel row at all, and `.presentationCompactAdaptation
/// (.sheet)` — added to force the standard action-sheet presentation — did
/// not change that. Confirmed live: an accessibility-tree dump still showed
/// a `Popover` container, no "Cancel" button anywhere, dismissal reachable
/// only by tapping a `PopoverDismissRegion` VoiceOver users can't discover
/// (device report: "I can't get the voiceover to dismiss the picker").
///
/// Cancel lives outside the `List`, in the enclosing `VStack`, not as a
/// trailing row inside it. Two earlier shapes both failed on the dedicated
/// test simulator, and a live accessibility-tree dump (with the sheet open,
/// scrolled to the top) pinned the second one directly: a `.toolbar` Cancel
/// never resolved hittable and once triggered "Multiple matching elements
/// found" for its own identifier; a Cancel placed as a second `Section`
/// after all 13 channel rows didn't exist in the tree *at all* — the dump's
/// last realized row was "Custom" (channel 13 of 13), followed by a large
/// unrendered placeholder region, because `List` is backed by a lazy,
/// virtualized `UICollectionView` that only materializes rows near the
/// visible viewport. A row placed after the full channel list is never
/// scrolled into view by anything in this flow, so it's simply never
/// instantiated. Cancel outside the `List` — in the `VStack` that also
/// holds it — is unconditionally instantiated and on screen regardless of
/// how many channels there are or where the list happens to be scrolled.
struct LogOtherChannelSheet: View {
    let onSelect: (Channel) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List(Channel.allCases, id: \.self) { channel in
                    Button(channel.displayName) {
                        onSelect(channel)
                    }
                }
                Button("Cancel", role: .cancel, action: onCancel)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("contact-detail.log-other-cancel")
            }
            .navigationTitle("Log other channel")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
