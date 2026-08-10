import SwiftUI

/// Simple "All Contacts" list for Phase 0 — full-featured search / sort lands
/// in a later phase. The main value of having it in the tab bar now is
/// navigating into Contact Detail from the shell.
public struct AllContactsScreen: View {
    @State private var viewModel: AllContactsViewModel
    @Binding private var searchText: String
    var rowConstructionObserver: (@MainActor (UUID) -> Void)?

    init(viewModel: AllContactsViewModel,
         searchText: Binding<String>) {
        self._viewModel = State(initialValue: viewModel)
        self._searchText = searchText
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
