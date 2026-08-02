import SwiftUI

/// Simple "All Contacts" list for Phase 0 — full-featured search / sort lands
/// in a later phase. The main value of having it in the tab bar now is
/// navigating into Contact Detail from the shell.
public struct AllContactsScreen: View {
    let env: AppEnvironment
    @State private var contacts: [Contact] = []
    @State private var now: Date = .distantPast
    @State private var searchText: String = ""

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                RegardsCard {
                    VStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, contact in
                            NavigationLink(value: contact.id) {
                                contactRow(contact)
                            }
                            .buttonStyle(.plain)
                            if idx < filtered.count - 1 { Hair(inset: 72) }
                        }
                    }
                }
                .padding(.top, 4)

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, prompt: "Search contacts")
        .accessibilityIdentifier("screen.contacts")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: UUID.self) { contactId in
            ContactDetailScreen(
                viewModel: ContactDetailViewModel(
                    contactId: contactId,
                    contacts: env.contacts,
                    interactionsRepo: env.interactions
                )
            )
        }
        .task {
            // Cache `now` alongside the fetched list so the "last X days ago"
            // strings stay consistent across re-renders — Date() inline per
            // row would recompute every update and drift across day
            // boundaries while the user sits on the screen.
            now = Date()
            do {
                contacts = try await env.contacts.fetchTracked()
                contacts.sort { $0.priorityTier.rawValue < $1.priorityTier.rawValue }
            } catch {
                Self.log.error("failed to load tracked contacts: \(error, privacy: .public)")
                contacts = []
            }
        }
    }

    static let log = RegardsLogger.feature("AllContacts")

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Contacts")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(RegardsDS.ink)
                .accessibilityAddTraits(.isHeader)
            Text("\(contacts.count) tracked")
                .font(.subheadline)
                .foregroundStyle(RegardsDS.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var filtered: [Contact] {
        guard !searchText.isEmpty else { return contacts }
        let q = searchText.lowercased()
        return contacts.filter { $0.displayName.lowercased().contains(q) }
    }

    private func contactRow(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            Avatar(name: contact.displayName, size: 40,
                   hasAccentRing: contact.priorityTier == .innerCircle)
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(RegardsDS.ink)
                Text(
                    [contact.cadenceDays.map { CadenceDescriptor.describe(days: $0) },
                     contact.lastInteractedAt.flatMap { Contact.relativeDescription(for: $0, from: now) }
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
