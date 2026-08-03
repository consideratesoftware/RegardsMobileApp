import SwiftUI

enum EditContactAccessibility {
    enum ValueSpeech {
        case verbatim
        case email
    }

    static func fieldLabel(
        _ label: String,
        displayedValue: String,
        speech: ValueSpeech
    ) -> String {
        guard !displayedValue.isEmpty else { return label }

        let spokenValue = switch speech {
        case .verbatim:
            displayedValue
        case .email:
            displayedValue
                .replacingOccurrences(of: "@", with: " at ")
                .replacingOccurrences(of: ".", with: " dot ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        return "\(label), \(spokenValue)"
    }
}

public struct EditContactScreen: View {
    let contact: Contact

    public init(contact: Contact) {
        self.contact = contact
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                heroAvatar
                readOnlyBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                nameSection
                phoneSection
                emailSection
                postalSection
                datesSection
                notesSection

                Color.clear.frame(height: 40)
            }
        }
        .background(RegardsDS.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("screen.edit-contact")
        .navigationTitle("Contact Preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        Text("Contact Preview")
            .font(.headline)
            .foregroundStyle(RegardsDS.ink)
            .frame(maxWidth: .infinity)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
    }

    private var heroAvatar: some View {
        VStack(spacing: 10) {
            Avatar(name: contact.displayName, size: 76)
            // Stub — Phase 1 wires the photo picker. Muted so it doesn't
            // look tap-affordable.
            Text("Change photo")
                .font(.subheadline)
                .foregroundStyle(RegardsDS.muted)
        }
        .padding(.top, 16)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private var readOnlyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("↪")
                .font(RegardsFont.mono(.caption))
                .foregroundStyle(RegardsDS.accentInk.opacity(0.8))
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(
                "Read-only preview. Contact editing is not available yet; "
                + "your device Contacts stay unchanged."
            )
            .font(.footnote)
            .foregroundStyle(RegardsDS.accentInk)
            .lineSpacing(2)
            .accessibilityIdentifier("edit-contact.read-only-banner")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RegardsDS.accentSoft, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Field sections

    private var nameSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Name")
            RegardsCard {
                VStack(spacing: 0) {
                    field("First", value: firstName)
                    Hair(inset: 16)
                    field("Last", value: lastName)
                }
            }
        }
    }

    private var phoneSection: some View {
        let isPhone = [Channel.phoneCall, .sms, .whatsapp, .signal, .facetime]
            .contains(contact.preferredChannel)
        return VStack(spacing: 0) {
            SectionHeader("Phone")
            RegardsCard {
                VStack(spacing: 0) {
                    field("mobile", value: isPhone ? contact.preferredChannelValue : "")
                    Hair(inset: 16)
                    field("home", placeholder: "Add phone")
                }
            }
        }
    }

    private var emailSection: some View {
        let isEmail = contact.preferredChannel == .email
        return VStack(spacing: 0) {
            SectionHeader("Email")
            RegardsCard {
                field("personal",
                      value: isEmail ? contact.preferredChannelValue : "",
                      placeholder: "Add email",
                      touched: isEmail,
                      speech: .email)
            }
        }
    }

    private var postalSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Postal address · for holiday cards")
            RegardsCard {
                field("home", placeholder: "Add address")
            }
        }
    }

    private var datesSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Dates")
            RegardsCard {
                VStack(spacing: 0) {
                    field("Birthday", placeholder: "Add birthday")
                    Hair(inset: 16)
                    field("Anniversary", placeholder: "Add anniversary")
                }
            }
        }
    }

    private var notesSection: some View {
        VStack(spacing: 0) {
            SectionHeader("Regards-local · not saved to Contacts")
            RegardsCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.footnote)
                        .foregroundStyle(RegardsDS.muted)
                    Text(contact.notes.isEmpty ? "No notes." : contact.notes)
                        .font(.subheadline)
                        .foregroundStyle(RegardsDS.ink)
                        .lineSpacing(3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Field row

    private func field(_ label: String,
                       value: String = "",
                       placeholder: String = "",
                       touched: Bool = false,
                       speech: EditContactAccessibility.ValueSpeech = .verbatim) -> some View {
        let displayedValue = value.isEmpty ? placeholder : value
        return HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(RegardsDS.muted)
                .frame(width: 84, alignment: .leading)
            HStack(spacing: 6) {
                Text(displayedValue)
                    .font(.body)
                    .foregroundStyle(value.isEmpty ? RegardsDS.muted : RegardsDS.ink)
                if touched {
                    Circle()
                        .fill(RegardsDS.accent)
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            EditContactAccessibility.fieldLabel(
                label,
                displayedValue: displayedValue,
                speech: speech
            )
        )
    }

    private var firstName: String {
        let parts = contact.displayName.split(whereSeparator: { $0.isWhitespace })
        return parts.first.map(String.init) ?? ""
    }

    private var lastName: String {
        let parts = contact.displayName.split(whereSeparator: { $0.isWhitespace })
        return parts.dropFirst().joined(separator: " ")
    }
}
