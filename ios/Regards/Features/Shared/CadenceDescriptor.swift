import Foundation

/// Human-readable cadence string used across the Overdue / Upcoming / Contact
/// Detail screens. Covers the common presets ("weekly", "monthly",
/// "quarterly") and falls back to a precise "every N days/weeks/months"
/// phrasing for anything custom.
public enum CadenceDescriptor {

    public static func describe(days: Int) -> String {
        switch days {
        // A 0 or negative cadence (corrupt data) gets no reminders
        // (`isCadenceEligible`), so it reads as Contact Detail's no-cadence
        // label rather than "every 0 weeks".
        case ..<1:            return "not tracked"
        case 1:               return "daily"
        case 7:               return "weekly"
        case 14:              return "every 2 weeks"
        case 21:              return "every 3 weeks"
        case 30, 31:          return "monthly"
        case 60, 61, 62:      return "every 2 months"
        case 90, 91, 92:      return "quarterly"
        case 180, 182, 183:   return "every 6 months"
        case 365, 366:        return "yearly"
        default:
            if days % 7 == 0 {
                return "every \(days / 7) weeks"
            }
            return "every \(days) days"
        }
    }
}
