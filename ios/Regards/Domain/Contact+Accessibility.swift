import Foundation

/// Natural-language description used as the VoiceOver label for a contact row
/// on the Overdue / Upcoming / Contacts screens (ARCHITECTURE.md accessibility
/// baseline, docs/accessibility.md). The label collapses what a sighted user
/// reads across avatar + name + status chip + channel pill into one spoken
/// sentence.
public extension Contact {

    struct AccessibilityContext: Sendable, Equatable {
        public let now: Date
        public let effectiveLastInteractedAt: Date?
        public let isOverdue: Bool
        public let overdueDays: Int
        public let isVirtualMerged: Bool

        public init(now: Date,
                    effectiveLastInteractedAt: Date?,
                    isOverdue: Bool,
                    overdueDays: Int,
                    isVirtualMerged: Bool = false) {
            self.now = now
            self.effectiveLastInteractedAt = effectiveLastInteractedAt
            self.isOverdue = isOverdue
            self.overdueDays = overdueDays
            self.isVirtualMerged = isVirtualMerged
        }
    }

    /// The spoken label. Example:
    ///
    ///   "Leia Organa, 9 days overdue, every 2 weeks, last contacted 3 weeks ago.
    ///    Inner-circle."
    ///
    /// Units pluralize correctly at 0/1/many and relative-time follows
    /// today / yesterday / N days ago / N weeks ago / N months ago / N years ago.
    func accessibilityLabel(context: AccessibilityContext) -> String {
        var parts: [String] = [displayName]

        if context.isVirtualMerged {
            parts.append("merged contact")
        }

        if !tracked {
            parts.append("not tracked")
            return parts.joined(separator: ", ") + "."
        }

        if context.isOverdue {
            parts.append(pluralizedDays(context.overdueDays) + " overdue")
        }

        if let cadence = cadenceDays {
            parts.append("every " + pluralizedDays(cadence))
        }

        let relative = Self.relativeDescription(
            for: context.effectiveLastInteractedAt, from: context.now)
        if let relative {
            parts.append("last contacted " + relative)
        }

        var sentence = parts.joined(separator: ", ")
        switch priorityTier {
        case .innerCircle:
            sentence += ". Inner circle."
        case .close, .regular, .acquaintance:
            sentence += "."
        }
        return sentence
    }

    /// Short "status chip" text that appears visually next to the row ("9d
    /// overdue"). Shared by the view-layer and VoiceOver to avoid drift.
    func statusChip(context: AccessibilityContext) -> String? {
        guard context.isOverdue else { return nil }
        return "\(context.overdueDays)d overdue"
    }

    // MARK: - Helpers

    private func pluralizedDays(_ count: Int) -> String {
        switch count {
        case 0:  return "0 days"
        case 1:  return "1 day"
        default: return "\(count) days"
        }
    }

    static func relativeDescription(for date: Date?, from now: Date) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return nil }
        let day: TimeInterval = 86_400
        let week: TimeInterval = day * 7
        let month: TimeInterval = day * 30
        let year: TimeInterval = day * 365

        if seconds < day {
            return "today"
        } else if seconds < 2 * day {
            return "yesterday"
        } else if seconds < week {
            return "\(Int(seconds / day)) days ago"
        } else if seconds < month {
            let w = Int(seconds / week)
            return w == 1 ? "1 week ago" : "\(w) weeks ago"
        } else if seconds < year {
            let m = Int(seconds / month)
            return m == 1 ? "1 month ago" : "\(m) months ago"
        } else {
            let y = Int(seconds / year)
            return y == 1 ? "1 year ago" : "\(y) years ago"
        }
    }
}
