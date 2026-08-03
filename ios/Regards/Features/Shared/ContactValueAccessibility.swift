import Foundation

enum ContactValueAccessibility {
    enum ValueSpeech {
        case verbatim
        case email
    }

    static func usesEmailField(channel: Channel, displayedValue: String) -> Bool {
        switch ChannelCatalog.metadata(for: channel).valueKind {
        case .email:
            return true
        case .phoneOrEmail:
            return ChannelCatalog.isEmail(
                displayedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        default:
            return false
        }
    }

    static func usesPhoneField(channel: Channel, displayedValue: String) -> Bool {
        switch ChannelCatalog.metadata(for: channel).valueKind {
        case .phoneE164:
            return true
        case .phoneOrEmail:
            return !usesEmailField(channel: channel, displayedValue: displayedValue)
        default:
            return false
        }
    }

    static func label(
        _ label: String,
        displayedValue: String,
        channel: Channel,
        annotation: String? = nil
    ) -> String {
        self.label(
            label,
            displayedValue: displayedValue,
            speech: speaksAsEmail(channel: channel, displayedValue: displayedValue) ? .email : .verbatim,
            annotation: annotation
        )
    }

    private static func speaksAsEmail(channel: Channel, displayedValue: String) -> Bool {
        let valueKind = ChannelCatalog.metadata(for: channel).valueKind
        guard valueKind == .email || valueKind == .phoneOrEmail else { return false }
        return ChannelCatalog.isEmail(
            displayedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func label(
        _ label: String,
        displayedValue: String,
        speech: ValueSpeech,
        annotation: String? = nil
    ) -> String {
        let trimmedValue = displayedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let valueAnnotation = trimmedValue.isEmpty ? nil : annotation
        let parts = [label, spokenValue(trimmedValue, speech: speech), valueAnnotation]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return parts.joined(separator: ", ")
    }

    private static func spokenValue(_ value: String, speech: ValueSpeech) -> String? {
        guard !value.isEmpty else { return nil }

        switch speech {
        case .verbatim:
            return value
        case .email:
            return value
                .replacingOccurrences(of: "@", with: " at ")
                .replacingOccurrences(of: ".", with: " dot ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
    }
}
