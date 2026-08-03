import Foundation

enum ContactValueAccessibility {
    enum ValueSpeech {
        case verbatim
        case email
    }

    static func label(
        _ label: String,
        displayedValue: String,
        speech: ValueSpeech,
        annotation: String? = nil
    ) -> String {
        let trimmedValue = displayedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [label, spokenValue(trimmedValue, speech: speech), annotation]
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
