import SwiftUI

/// Pick up to 3 people to keep in touch with, and how often (TF-11, §14
/// PR29). Reached from Settings and from the onboarding flow, which shows
/// the same screen with `showsSkip` on, since it has no back button.
///
/// The importer's channel is shown read-only on each row. Per-contact channel
/// choice belongs to Contact Detail (R58), not here.
///
/// Needs a navigation container for the search field. Settings provides one;
/// the onboarding flow must wrap this screen in a `NavigationStack`.
struct StarterContactsScreen: View {
    /// `@State`, not a plain property: a navigation destination closure runs
    /// again on every root re-render and hands over a fresh view model each
    /// time. `State` keeps the first one while the screen is showing, so
    /// picks survive a re-render and a new push starts clean.
    @State private var viewModel: StarterContactsViewModel
    private let showsSkip: Bool
    /// Under limited Contacts access Regards can read only the contacts the
    /// user shared, so the screen says so and where to share more (owner
    /// ruling, 2026-10-17: no in-app picker).
    private let showsLimitedAccessNote: Bool
    /// Contacts access is denied, restricted or not yet asked (Settings
    /// route). The empty state then points at the Contacts access row above
    /// instead of saying nothing was imported.
    private let contactsAccessIsOff: Bool
    private let onFinish: () -> Void
    @State private var searchText = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        viewModel: StarterContactsViewModel,
        showsSkip: Bool = false,
        showsLimitedAccessNote: Bool = false,
        contactsAccessIsOff: Bool = false,
        onFinish: @escaping () -> Void
    ) {
        self._viewModel = State(initialValue: viewModel)
        self.showsSkip = showsSkip
        self.showsLimitedAccessNote = showsLimitedAccessNote
        self.contactsAccessIsOff = contactsAccessIsOff
        self.onFinish = onFinish
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                switch viewModel.loadState {
                case .loading:
                    ProgressView("Loading contacts")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                case .failed:
                    loadFailure
                case .loaded:
                    list
                }
                Color.clear.frame(height: 24)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("screen.starter-contacts")
        .searchable(text: $searchText, prompt: "Search contacts")
        // After the identifier above: a container identifier applied to the
        // inset too would replace the ids on Done, Skip and the message.
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // A re-appearance (the keyboard, a popover closing) must not reload
        // over unsaved picks.
        .task {
            if viewModel.loadState == .loading { await viewModel.load() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Who do you want to keep in touch with?")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(RegardsDS.ink)
                .accessibilityAddTraits(.isHeader)
            Text("pick up to 3 to start.")
                .font(RegardsFont.serifItalic(.title3))
                .foregroundStyle(RegardsDS.muted)
            if viewModel.loadState == .loaded {
                Text(viewModel.countSummary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RegardsDS.ink)
                    .padding(.top, 8)
                    .accessibilityIdentifier("starter.count")
            }
            if showsLimitedAccessNote {
                Text(
                    "Regards can only see the contacts you shared with it. "
                    + "To add more people, change Contacts access for Regards in iOS Settings."
                )
                .font(.footnote)
                .foregroundStyle(RegardsDS.muted)
                .padding(.top, 6)
                .accessibilityIdentifier("starter.limited-note")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        let visible = viewModel.filtered(searchText: searchText)
        if viewModel.contacts.isEmpty {
            ContentUnavailableView {
                Label("No contacts to choose from", systemImage: "person.2")
            } description: {
                Text(
                    contactsAccessIsOff
                        ? "Regards can't see your contacts. Turn on Contacts access above to choose people."
                        : "Regards hasn't imported any contacts yet."
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .accessibilityIdentifier("starter.empty")
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
        } else {
            RegardsCard {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { contact in
                        contactBlock(contact)
                        if contact.id != visible.last?.id { Hair(inset: 68) }
                    }
                }
            }
        }
    }

    private func contactBlock(_ contact: Contact) -> some View {
        VStack(spacing: 0) {
            contactRow(contact)
            if viewModel.isSelected(contact.id) {
                cadenceRow(contact)
            }
        }
    }

    private func contactRow(_ contact: Contact) -> some View {
        let isSelected = viewModel.isSelected(contact.id)
        return Button {
            viewModel.toggle(contact.id)
        } label: {
            HStack(spacing: 12) {
                Avatar(name: contact.displayName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(RegardsDS.ink)
                    HStack(spacing: 6) {
                        ChannelGlyph(channel: contact.preferredChannel, size: 14)
                        Text(contact.preferredChannel.displayName)
                            .font(.footnote)
                            .foregroundStyle(RegardsDS.muted)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? RegardsDS.accentInk : RegardsDS.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The picks are being written; the view model ignores edits too.
        .disabled(viewModel.isSaving || viewModel.isFinished)
        .accessibilityLabel(contact.displayName)
        .accessibilityValue(contact.preferredChannel.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("starter.contact.\(contact.displayName)")
    }

    private func cadenceRow(_ contact: Contact) -> some View {
        let binding = Binding<Int>(
            get: { viewModel.cadenceDays(for: contact.id) ?? StarterContactsViewModel.defaultCadenceDays },
            set: { viewModel.setCadence($0, for: contact.id) }
        )
        return HStack {
            Picker(selection: binding) {
                ForEach(viewModel.cadenceChoices(for: contact.id)) { choice in
                    Text(choice.title).tag(choice.days)
                }
            } label: {
                Text("How often")
            }
            .pickerStyle(.menu)
            .disabled(viewModel.isSaving || viewModel.isFinished)
            .tint(RegardsDS.accentInk)
            .frame(minHeight: 44)
            .accessibilityLabel("How often for \(contact.displayName)")
            .accessibilityIdentifier("starter.cadence.\(contact.displayName)")
            Spacer(minLength: 0)
        }
        .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 16 : 68)
        .padding(.trailing, 16)
        .padding(.bottom, 8)
    }

    private var loadFailure: some View {
        ContentUnavailableView {
            Label("Unable to load contacts", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Your contacts are still on this device. Try loading them again.")
        } actions: {
            Button("Try Again") { Task { await viewModel.load() } }
                .buttonStyle(.borderedProminent)
                .tint(RegardsDS.accentInk)
                .frame(minHeight: 44)
                .accessibilityIdentifier("starter.retry")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    // MARK: - Actions

    private var actionBar: some View {
        VStack(spacing: 6) {
            if let message = viewModel.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(viewModel.statusIsProblem ? RegardsDS.danger : RegardsDS.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("starter.message")
            }
            if viewModel.loadState == .loaded {
                Button {
                    Task { if await viewModel.save() { onFinish() } }
                } label: {
                    Text(viewModel.isSaving ? "Saving…" : "Done")
                        .font(.headline)
                        .foregroundStyle(RegardsDS.background)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .padding(.vertical, 8)
                        .background(
                            RegardsDS.accentInk.opacity(viewModel.canSave ? 1 : 0.4),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canSave)
                .accessibilityIdentifier("starter.done")
            }
            if showsSkip {
                Button {
                    if viewModel.skip() { onFinish() }
                } label: {
                    Text("Skip for now")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(RegardsDS.accentInk)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSaving || viewModel.isFinished)
                .accessibilityIdentifier("starter.skip")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(RegardsDS.background.ignoresSafeArea())
    }
}
