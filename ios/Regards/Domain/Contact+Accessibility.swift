import Foundation

/// Natural-language description used as the VoiceOver label for Overdue's
/// contact row (ARCHITECTURE.md accessibility baseline, docs/accessibility.md
/// — the "Contacts" screen this doc comment used to also name never actually
/// called this; corrected, staged review round 11). Mirrors the visible row
/// exactly per `ios/docs/accessibility.md`'s "labels mirror visible content"
/// rule: name + how overdue, nothing the row doesn't also show.
public extension Contact {

    struct AccessibilityContext: Sendable, Equatable {
        public let now: Date
        public let isOverdue: Bool
        public let overdueDays: Int

        public init(now: Date,
                    isOverdue: Bool,
                    overdueDays: Int) {
            self.now = now
            self.isOverdue = isOverdue
            self.overdueDays = overdueDays
        }
    }

    /// The spoken label. Example: "Leia Organa, 9 days overdue. Inner circle."
    ///
    /// Cadence and last-contacted dropped (staged review round 11): Sid
    /// overruled an earlier "keep the fuller spoken context" call with a
    /// standing principle recorded in `ios/docs/accessibility.md` — labels
    /// mirror visible content unless a departure is written down at the
    /// site, and this one had no such exception to claim. That information
    /// stays reachable on Contact Detail; it just isn't repeated here
    /// anymore, matching what the row itself now shows.
    ///
    /// Units pluralize correctly at 0/1/many.
    func accessibilityLabel(context: AccessibilityContext) -> String {
        var parts: [String] = [displayName]

        // No "merged contact" branch here (staged review round 11): the
        // visual chip it described was removed from Overdue's row — see
        // `OverdueRowState`'s doc comment — and a spoken label describing
        // something no longer on screen is its own bug, not a courtesy.
        // Merge provenance now lives only on Merge Duplicates, which reads
        // its own state directly rather than through this shared label.

        if !tracked {
            parts.append("not tracked")
            return parts.joined(separator: ", ") + "."
        }

        if context.isOverdue {
            parts.append(pluralizedDays(context.overdueDays) + " overdue")
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
