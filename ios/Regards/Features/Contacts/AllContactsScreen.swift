import SwiftUI

/// Simple "All Contacts" list for Phase 0 — full-featured search / sort lands
/// in a later phase. The main value of having it in the tab bar now is
/// navigating into Contact Detail from the shell.
public struct AllContactsScreen: View {
    @State private var viewModel: AllContactsViewModel
    @Binding private var searchText: String
    /// Tracks whether this screen is the currently-displayed tab, via
    /// `.onAppear`/`.onDisappear` below — SwiftUI fires those for a
    /// `TabView` tab's content on every switch into/out of it, even though
    /// the content stays mounted (and `.task`/`.onChange` keep running) the
    /// whole time it's just a background tab. Gates the corruption
    /// announcement (round 10): a `CNContactStoreDidChange` reconciling
    /// while the user sits on Overdue/Detail/Settings still reloads this
    /// screen's data (`reconciliationGeneration` doesn't care which tab is
    /// frontmost), but interrupting VoiceOver on a *different* screen to
    /// announce a Contacts-tab banner the user isn't looking at is wrong —
    /// they'll reach the banner in normal reading order whenever they do
    /// arrive at this tab.
    @State private var isCurrentlyVisible = false
    /// Bumped by `AppLaunchCoordinator.reconciliationCount` (threaded down
    /// through `RootView` → `RegardsTabRoot` → here) once per completed
    /// reconciliation pass. Reloading on this instead of raw `scenePhase`
    /// matters: `scenePhase` becoming `.active` and the coordinator's
    /// `handleSceneActivation()` fire at the same moment with no ordering
    /// guarantee between them, so a scene-phase-driven reload almost always
    /// wins the race and reads the store *before* reconciliation finishes
    /// enumerating — and a `CNContactStoreDidChange` arriving while the user
    /// already sits on this tab (no foreground transition at all) never
    /// reloads it. `reconciliationCount` only increments strictly *after*
    /// a pass completes, for every trigger (launch, foreground, and
    /// store-change alike), so this is always correct-after-the-fact.
    let reconciliationGeneration: Int
    var rowConstructionObserver: (@MainActor (UUID) -> Void)?
    /// Test-only hook mirroring `rowConstructionObserver`'s shape: fires
    /// alongside `isCurrentlyVisible`'s own assignment in `.onAppear`/
    /// `.onDisappear` below. `isCurrentlyVisible` itself is private state a
    /// test can't read directly, and SwiftUI dispatches `.onAppear`/
    /// `.onDisappear` on its own run-loop schedule — a `window.layoutIfNeeded()`
    /// after a programmatic tab switch doesn't guarantee they've already
    /// fired. A test asserting the announcement gate stays *closed* needs a
    /// way to settle to "the disappear transition has actually landed"
    /// before it drives the state that would trigger an announcement,
    /// otherwise it's racing SwiftUI's own scheduling instead of proving
    /// the gate.
    var visibilityChangeObserver: (@MainActor (Bool) -> Void)?
    var corruptionAnnouncementEffects = AllContactsCorruptionAnnouncementEffects.live

    init(
        viewModel: AllContactsViewModel,
        searchText: Binding<String>,
        reconciliationGeneration: Int = 0
    ) {
        self._viewModel = State(initialValue: viewModel)
        self._searchText = searchText
        self.reconciliationGeneration = reconciliationGeneration
    }

    public var body: some View {
        // Filter once per body evaluation. Keeping this value local is
        // important for a production-sized address book: reading a computed
        // filter from every row turns an otherwise linear search into
        // quadratic work while SwiftUI builds the list.
        let visibleContacts = viewModel.filtered(searchText: searchText)

        ScrollView {
            VStack(spacing: 0) {
                Text(viewModel.summary)
                    .font(.subheadline)
                    .foregroundStyle(RegardsDS.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 8)

                if let corruptionMessage = viewModel.corruptionMessage {
                    corruptionBanner(corruptionMessage)
                }

                listContent(visibleContacts)

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, prompt: "Search contacts")
        .accessibilityIdentifier("screen.contacts")
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await viewModel.load()
        }
        .onAppear {
            isCurrentlyVisible = true
            visibilityChangeObserver?(true)
        }
        .onDisappear {
            isCurrentlyVisible = false
            visibilityChangeObserver?(false)
        }
        .onChange(of: reconciliationGeneration) { _, _ in
            // §14 PR21 acceptance: a contact deleted/re-added/renamed in the
            // system app reflects here "next foreground" — and, for free,
            // on a `CNContactStoreDidChange` that lands while this tab is
            // already on-screen. See `reconciliationGeneration`'s doc
            // comment for why this fires here instead of on `scenePhase`.
            // Overdue and Upcoming get their own live-list wiring in TF-04,
            // not here.
            Task { await viewModel.load() }
        }
        .onChange(of: viewModel.corruptionMessage, initial: true) { previous, message in
            // Announce only the nil → non-nil transition, whether that's the
            // first load or a later `reconciliationGeneration`-driven
            // reload — not every change while it stays non-nil (the count
            // shifting from 1 to 2 corrupt rows doesn't need a fresh
            // interruption) and not when it clears. And only while this
            // screen is the one actually on screen (`isCurrentlyVisible`) —
            // a reload that happens while the user is elsewhere shouldn't
            // interrupt whatever they're doing there; they'll reach the
            // banner in reading order when they arrive at this tab.
            guard previous == nil, let message, isCurrentlyVisible else { return }
            corruptionAnnouncementEffects.announce(message)
        }
    }

    @ViewBuilder
    private func listContent(_ visibleContacts: [Contact]) -> some View {
        switch viewModel.loadState {
        case .loading:
            ProgressView("Loading contacts")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        case .failed:
            loadError
        case .loaded where visibleContacts.isEmpty:
            emptyState
        case .loaded:
            RegardsCard {
                LazyVStack(spacing: 0) {
                    ForEach(visibleContacts) { contact in
                        NavigationLink(value: contact.id) {
                            contactRow(contact)
                        }
                        .buttonStyle(.plain)
                        .regardsContactTransitionSource(id: contact.id)
                        if contact.id != visibleContacts.last?.id { Hair(inset: 72) }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    /// Non-interactive: R50 asks that a corrupt row stay visible rather than
    /// vanishing (or hiding the rest of the list) — not that the user takes
    /// an action here. There's nothing to tap yet; a future PR can add a
    /// "Learn more" / support-export path once one exists.
    private func corruptionBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(RegardsDS.ink)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .foregroundStyle(RegardsDS.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contacts.corruption-banner")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            if searchText.isEmpty {
                Label("No contacts yet", systemImage: "person.2")
            } else {
                Label("No results", systemImage: "magnifyingglass")
            }
        } description: {
            if searchText.isEmpty {
                Text("Imported contacts will appear here.")
            } else {
                Text("No contacts match “\(searchText)”.")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    private var loadError: some View {
        ContentUnavailableView {
            Label("Unable to load contacts", systemImage: "exclamationmark.triangle")
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

    private func contactRow(_ contact: Contact) -> some View {
        rowConstructionObserver?(contact.id)

        return HStack(spacing: 12) {
            Avatar(name: contact.displayName, size: 40,
                   hasAccentRing: contact.priorityTier == .innerCircle)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(RegardsDS.ink)
                Text(
                    [contact.cadenceDays.map { CadenceDescriptor.describe(days: $0) },
                     contact.lastInteractedAt.flatMap {
                        Contact.relativeDescription(for: $0, from: viewModel.now)
                     }
                        .map { "last \($0)" }]
                    .compactMap { $0 }.joined(separator: " · ")
                )
                .font(.footnote)
                .foregroundStyle(RegardsDS.muted)
            }
            Spacer()
            ChannelGlyph(channel: contact.preferredChannel, size: 14)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Injectable so tests can assert an announcement fired without a live
/// VoiceOver session — same shape as `LaunchFailureAccessibilityEffects`
/// (`RegardsApp.swift`) and `OnboardingAccessibilityEffects`
/// (`OnboardingScreen.swift`).
struct AllContactsCorruptionAnnouncementEffects {
    let announce: @MainActor (String) -> Void

    static let live = AllContactsCorruptionAnnouncementEffects(
        announce: { AccessibilityNotification.Announcement($0).post() }
    )
}
