import SwiftUI

public struct MergeDuplicatesScreen: View {
    let viewModel: MergeDuplicatesViewModel

    public init(viewModel: MergeDuplicatesViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                summaryRule
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 18)

                if viewModel.candidates.isEmpty {
                    empty
                } else {
                    ForEach(viewModel.candidates) { candidate in
                        CandidateCard(
                            state: candidate,
                            onTapPrimary: { isA in
                                viewModel.setPrimary(for: candidate.id, isA: isA)
                            },
                            onTapMerge: {
                                viewModel.toggleSelection(for: candidate.id)
                            }
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("screen.merge-duplicates")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Find duplicates")
                .font(.system(.largeTitle, weight: .bold))
                .foregroundStyle(RegardsDS.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Group two entries under one reminder. Nothing is merged in your address book — only in Regards.")
                .font(.subheadline)
                .foregroundStyle(RegardsDS.muted)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var summaryRule: some View {
        HStack(spacing: 14) {
            Text("\(viewModel.candidates.count) candidate\(viewModel.candidates.count == 1 ? "" : "s")")
                .font(RegardsFont.mono(.caption))
                .foregroundStyle(RegardsDS.muted)
            Hair().frame(maxWidth: .infinity)
            Text("ranked by strength")
                .font(RegardsFont.mono(.caption))
                .foregroundStyle(RegardsDS.muted)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No duplicates found.")
                .font(RegardsFont.serifItalic(.title))
                .foregroundStyle(RegardsDS.ink)
            Text("Regards didn't find any contacts that look like duplicates.")
                .font(.subheadline)
                .foregroundStyle(RegardsDS.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 40)
    }
}

struct CandidateCard: View {
    let state: DuplicateCandidateState
    let onTapPrimary: (Bool) -> Void
    let onTapMerge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RegardsTag(state.confidence == .high ? "high match"
                           : state.confidence == .medium ? "probable match" : "name only",
                           tone: state.confidence == .high ? .accent : .neutral)
                Text(state.rationale)
                    .font(RegardsFont.mono(.caption))
                    .foregroundStyle(RegardsDS.muted)
                Spacer()
                // Stub — Phase 1 wires skip-candidate persistence. Muted
                // until interactive.
                Text("Skip")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(RegardsDS.muted)
            }

            HStack(spacing: 10) {
                candidateTile(
                    state.a,
                    isPrimary: state.primaryIsA,
                    identifier: "merge-duplicates.primary-a",
                    onTap: { onTapPrimary(true) }
                )
                candidateTile(
                    state.b,
                    isPrimary: !state.primaryIsA,
                    identifier: "merge-duplicates.primary-b",
                    onTap: { onTapPrimary(false) }
                )
            }

            Button(action: onTapMerge) {
                Text(state.isSelected ? "Merge virtually" : "Not a match")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.isSelected ? .white : RegardsDS.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(
                        // `accentInk` so the white headline passes AA body contrast.
                        state.isSelected ? RegardsDS.accentInk : RegardsDS.hairSoft,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("merge-duplicates.selection")
            .accessibilityHint("Virtual merge only — your system Contacts are never modified.")
        }
        .padding(14)
        .background(RegardsDS.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(state.isSelected ? RegardsDS.accent : RegardsDS.hair, lineWidth: state.isSelected ? 2 : 0.5)
        )
    }

    private func candidateTile(_ member: DuplicateCandidateState.Member,
                               isPrimary: Bool,
                               identifier: String,
                               onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Avatar(name: member.displayName, size: 36)
                    if isPrimary {
                        Text("PRIMARY")
                            .font(.caption2.weight(.bold))
                            .kerning(0.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(RegardsDS.accentInk))
                            .offset(x: 10, y: -6)
                    }
                }
                Text(member.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(RegardsDS.ink)
                    .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    if let phone = member.phone {
                        Text(phone).font(RegardsFont.mono(.caption))
                    }
                    if let email = member.email {
                        Text(email).font(RegardsFont.mono(.caption))
                    }
                }
                .foregroundStyle(RegardsDS.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RegardsDS.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isPrimary ? RegardsDS.accent : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(candidateAccessibilityLabel(member, isPrimary: isPrimary))
        .accessibilityHint(isPrimary ? "Currently set as primary." : "Double-tap to make primary.")
    }

    private func candidateAccessibilityLabel(
        _ member: DuplicateCandidateState.Member,
        isPrimary: Bool
    ) -> String {
        var parts = [member.displayName]
        if let phone = member.phone {
            parts.append(ContactValueAccessibility.label(
                "Phone",
                displayedValue: phone,
                speech: .verbatim
            ))
        }
        if let email = member.email {
            parts.append(ContactValueAccessibility.label(
                "Email",
                displayedValue: email,
                speech: .email
            ))
        }
        if isPrimary {
            parts.append("primary")
        }
        return parts.joined(separator: ", ")
    }
}
