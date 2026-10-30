import SwiftUI

/// The live reminder-window editor (ARCHITECTURE.md §10 screen 9). The same
/// screen edits the global window and, from Contact Detail, one contact's
/// override; an override shows days, ranges, and quiet hours only.
/// Morning-of time and the Upcoming horizon stay global.
public struct ReminderWindowsScreen: View {
    /// `@State`, not a plain property: the Settings destination closure runs
    /// again on every root re-render and hands over a fresh view model each
    /// time. `State` keeps the first one for as long as this screen is on the
    /// stack, so edits survive a re-render and a new push starts clean.
    @State var viewModel: ReminderWindowsViewModel
    private let announce: @MainActor (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var errorFocused: Bool
    /// Where VoiceOver lands after Remove range takes the focused button away.
    /// Internal, not private: `+Sections` sets it.
    @AccessibilityFocusState var addRangeFocused: Bool
    @State private var announcer = RowActionAnnouncer()
    @ScaledMetric(relativeTo: .subheadline) var pillSize: CGFloat = 36

    public init(viewModel: ReminderWindowsViewModel,
                announce: @escaping @MainActor (String) -> Void = {
                    AccessibilityNotification.Announcement($0).post()
                }) {
        self._viewModel = State(initialValue: viewModel)
        self.announce = announce
    }

    private var isOverride: Bool {
        if case .contact = viewModel.target { return true }
        return false
    }

    /// Scroll id for the inline error banner. It is not an accessibility
    /// identifier: `reminder-windows.error` is on the banner's message `Text`.
    private static let errorBannerID = "reminder-windows.error-banner"

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    header
                    switch viewModel.loadState {
                    case .loading:
                        ProgressView("Loading")
                            .padding(.top, 40)
                    case .failed:
                        loadFailure
                    case .loaded:
                        editor
                    }
                }
            }
            // Save sits in the toolbar, so the user is usually scrolled
            // away from the banner at the top. Scroll to it first, then move
            // focus there and speak the message: a focus change flushes
            // VoiceOver's speech queue, so announcing first would cut the
            // message off (same order as `RowActionAnnouncer` gives Overdue
            // and Upcoming). No animation, so Reduce Motion needs no branch.
            // Centered, not top-aligned: top alignment slid the header half
            // under the navigation bar, which the accessibility audit flags
            // as potentially inaccessible text.
            .onChange(of: viewModel.failureCount) {
                guard let message = viewModel.validationMessage else { return }
                proxy.scrollTo(Self.errorBannerID, anchor: .center)
                speak(message) { errorFocused = true }
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("screen.reminder-windows")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // The pass runs before the editor closes, so Save says it's
                // still working.
                Button(viewModel.saveButtonTitle) {
                    Task { if await viewModel.save() { dismiss() } }
                }
                .disabled(viewModel.loadState != .loaded || viewModel.isSaving)
                .accessibilityIdentifier("reminder-windows.save")
            }
        }
        // A re-appearance (a popover closing, a tab switch back) must not
        // reload over unsaved edits.
        .task {
            if viewModel.loadState == .loading { await viewModel.load() }
        }
    }

    /// Speaks `message` through the injectable `announce` seam, after `focus`
    /// when the caller moves VoiceOver focus first.
    func speak(_ message: String, focus: (@MainActor () -> Void)?) {
        announcer.fire(
            message,
            effects: RowActionAccessibilityEffects(announce: announce, didFocus: {}),
            focus: focus
        )
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let message = viewModel.validationMessage {
                errorBanner(message)
            }
            // The whole form is disabled and dimmed while a save or reset
            // runs its pass: an edit made then would be dropped when the
            // editor closes. The plain-styled pills and buttons don't dim on
            // their own.
            Group {
                daysSection
                timeRangesSection
                quietHoursSection
                if isOverride {
                    overrideNote
                    if viewModel.hasStoredOverride { resetButton }
                } else {
                    occasionSection
                    horizonSection
                }
            }
            .disabled(viewModel.isSaving)
            .opacity(viewModel.isSaving ? 0.5 : 1)
            Text("All times local · \(viewModel.timezoneName). Daylight saving time is handled automatically.")
                .font(.caption)
                .foregroundStyle(RegardsDS.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 22)
            Color.clear.frame(height: 40)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isOverride ? "Reminder window" : "Reminder windows")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(RegardsDS.ink)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(RegardsFont.serifItalic(.title3))
                .foregroundStyle(RegardsDS.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var subtitle: String {
        if isOverride {
            return "just for \(viewModel.contactName ?? "this contact")."
        }
        return "when it's OK to nudge you."
    }

    private var loadFailure: some View {
        ContentUnavailableView {
            Label("Can't load the window", systemImage: "exclamationmark.triangle")
        } description: {
            Text(viewModel.loadFailureMessage)
        } actions: {
            Button("Try Again") { Task { await viewModel.load() } }
                .frame(minHeight: 44)
                .accessibilityIdentifier("reminder-windows.retry")
        }
        .padding(.top, 24)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(RegardsDS.accentInk)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(RegardsDS.accentInk)
                .accessibilityIdentifier("reminder-windows.error")
                .accessibilityFocused($errorFocused)
        }
        .id(Self.errorBannerID)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RegardsDS.accentSoft, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Override extras

    private var overrideNote: some View {
        Text("Morning-of time and the Upcoming horizon follow the default window.")
            .font(.footnote)
            .foregroundStyle(RegardsDS.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
    }

    private var resetButton: some View {
        Button {
            Task { if await viewModel.resetToDefault() { dismiss() } }
        } label: {
            Text("Use default window")
                .font(.body.weight(.medium))
                .foregroundStyle(RegardsDS.accentInk)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("reminder-windows.use-default")
        .padding(.top, 8)
    }
}
