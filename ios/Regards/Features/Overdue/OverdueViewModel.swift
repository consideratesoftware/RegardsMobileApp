import Foundation
import Observation

/// Shape the view renders per contact — precomputed in the view model so the
/// view body stays formatting-free.
public struct OverdueRowState: Sendable, Identifiable, Equatable {
    public var id: UUID { contactId }
    public let contactId: UUID
    public let name: String
    public let priority: PriorityTier
    public let isVirtualMerged: Bool
    public let overdueDays: Int
    public let cadenceText: String
    public let lastInteractedText: String?
    public let channel: Channel
    public let channelLabel: String
    public let channelValue: String
    public let accessibilityLabel: String
}

/// `@MainActor` so mutations to `rows` / `selectedTab` are guaranteed to run
/// on the main actor — the view updates are main-actor-only and every call
/// site (view `.task`, tab-root init) is already main-actor. No
/// `@unchecked Sendable` needed; the class doesn't cross actors.
@Observable @MainActor
public final class OverdueViewModel {

    public private(set) var rows: [OverdueRowState] = []
    public private(set) var nextDigestLabel: String = "next digest at 6:00 pm"
    private(set) var loadState: RegardsLoadState = .loading

    private let contacts: any ContactRepository
    private let clock: () -> Date
    private let calendar: Calendar

    /// `calendar` is injected so tests (and future multi-timezone logic)
    /// can pin the day math to a fixed TZ. Production uses `.current`
    /// (user-local), which drifts from `window.timeZone` when the user
    /// travels — "6d overdue" computed here may disagree by one calendar
    /// day with "fires today" computed against the window's TZ in
    /// `ReminderEngine`. Intentional: the overdue label describes the
    /// user's perception right now, not the scheduling clock.
    public init(contacts: any ContactRepository,
                clock: @escaping () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.contacts = contacts
        self.clock = clock
        self.calendar = calendar
    }

    public func load() async {
        loadState = .loading
        do {
            let all = try await contacts.fetchTracked()
            let now = clock()
            rows = all.compactMap { Self.makeOverdueRow(for: $0, now: now, calendar: calendar) }
                .filter { $0.overdueDays > 0 }
                .sorted {
                    if $0.priority.rawValue != $1.priority.rawValue {
                        return $0.priority.rawValue < $1.priority.rawValue
                    }
                    return $0.overdueDays > $1.overdueDays
                }
            loadState = .loaded
        } catch {
            Self.log.error("failed to load tracked contacts: \(error, privacy: .public)")
            rows = []
            loadState = .failed
        }
    }

    public var innerCircleRows: [OverdueRowState] { rows.filter { $0.priority == .innerCircle } }
    public var closeFriendRows: [OverdueRowState] { rows.filter { $0.priority == .close } }
    public var otherRows: [OverdueRowState] {
        rows.filter { $0.priority == .regular || $0.priority == .acquaintance }
    }

    public var overdueCount: Int { rows.count }

    static let log = RegardsLogger.feature("Overdue")

    static func makeOverdueRow(for contact: Contact,
                               now: Date,
                               calendar: Calendar) -> OverdueRowState? {
        guard contact.tracked, let cadenceDays = contact.cadenceDays else { return nil }
        let last = contact.lastInteractedAt ?? contact.createdAt
        let overdueAt = last.addingTimeInterval(TimeInterval(cadenceDays) * 86_400)

        // DST-correct day count: Calendar.dateComponents honors calendar
        // boundaries; raw seconds/86_400 is off across DST transitions and
        // in timezones near day boundaries.
        let days = calendar.dateComponents([.day], from: overdueAt, to: now).day ?? 0
        let overdueDays = max(0, days)

        let context = Contact.AccessibilityContext(
            now: now,
            effectiveLastInteractedAt: contact.lastInteractedAt,
            isOverdue: overdueDays > 0,
            overdueDays: overdueDays
        )

        return OverdueRowState(
            contactId: contact.id,
            name: contact.displayName,
            priority: contact.priorityTier,
            isVirtualMerged: contact.contactGroupId != nil,
            overdueDays: overdueDays,
            cadenceText: CadenceDescriptor.describe(days: cadenceDays),
            lastInteractedText: contact.lastInteractedAt.flatMap {
                Contact.relativeDescription(for: $0, from: now)
            },
            channel: contact.preferredChannel,
            channelLabel: contact.preferredChannel.displayName,
            channelValue: contact.preferredChannelValue,
            accessibilityLabel: contact.accessibilityLabel(context: context)
        )
    }
}
