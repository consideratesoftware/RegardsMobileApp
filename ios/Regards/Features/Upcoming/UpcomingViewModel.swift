import Foundation
import Observation

public struct UpcomingRowState: Sendable, Identifiable, Equatable {
    public struct RowID: Sendable, Hashable {
        public let contactId: UUID
        public let kind: ReminderKind
        public let reminderId: UUID?

        public init(contactId: UUID, kind: ReminderKind, reminderId: UUID? = nil) {
            self.contactId = contactId
            self.kind = kind
            self.reminderId = reminderId
        }
    }

    public let id: RowID
    public let contactId: UUID
    public let name: String
    public let kind: ReminderKind
    public let scheduledFor: Date
    public let channel: Channel
    public let cadenceText: String?
    public let occasionText: String?
    public let timeOfDayText: String
    public let dayHeader: String
}

@Observable @MainActor
public final class UpcomingViewModel {

    public private(set) var groups: [(header: String, rows: [UpcomingRowState])] = []
    public private(set) var totalCount: Int = 0
    private(set) var loadState: RegardsLoadState = .loading

    public var horizonDays: Int = 14

    private let contacts: any ContactRepository
    private let reminders: (any ReminderRepository)?
    private let engine: ReminderEngine
    private let window: ReminderWindow
    private let clock: () -> Date
    private var loadGeneration = 0

    public init(contacts: any ContactRepository,
                reminders: (any ReminderRepository)? = nil,
                engine: ReminderEngine = ReminderEngine(),
                window: ReminderWindow = .defaultV1(),
                clock: @escaping () -> Date = { Date() }) {
        self.contacts = contacts
        self.reminders = reminders
        self.engine = engine
        self.window = window
        self.clock = clock
    }

    public func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        if loadState != .loaded {
            loadState = .loading
        }
        do {
            let tracked = try await contacts.fetchTracked()
            let pendingReminders = try await reminders?.fetchAllPending() ?? []
            let now = clock()
            let rows = buildRows(
                contacts: tracked,
                reminders: pendingReminders,
                now: now
            )
            guard generation == loadGeneration else { return }
            totalCount = rows.count
            groups = group(rows: rows)
            loadState = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            Self.log.error("failed to load upcoming reminders: \(error, privacy: .public)")
            groups = []
            totalCount = 0
            loadState = .failed
        }
    }

    static let log = RegardsLogger.feature("Upcoming")

    // MARK: - Formatters (cached per timezone, locale-pinned)
    //
    // DateFormatter construction is slow, the format we want — "h:mm a" with
    // lowercase am/pm — is locale-sensitive without an explicit POSIX pin,
    // and mutating a shared formatter's `timeZone` per call is fragile
    // (Swift 6 strict concurrency would also flag a single non-Sendable
    // static being written from multiple call sites). We cache one formatter
    // per TZ identifier, created on first use and reused forever after.
    //
    // `@MainActor` on the caches matches the isolation of every call site
    // (every view model is `@MainActor`) — static members don't inherit
    // class isolation, so this has to be explicit.

    @MainActor
    private static var timeFormattersByTZ: [String: DateFormatter] = [:]

    @MainActor
    private static var dayHeaderFormattersByTZ: [String: DateFormatter] = [:]

    @MainActor
    private static var calendarsByTZ: [String: Calendar] = [:]

    @MainActor
    static func timeFormatter(for timezone: TimeZone) -> DateFormatter {
        let key = timezone.identifier
        if let existing = timeFormattersByTZ[key] { return existing }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "h:mm a"
        df.amSymbol = "am"
        df.pmSymbol = "pm"
        df.timeZone = timezone
        timeFormattersByTZ[key] = df
        return df
    }

    @MainActor
    static func dayHeaderSuffixFormatter(for timezone: TimeZone) -> DateFormatter {
        let key = timezone.identifier
        if let existing = dayHeaderFormattersByTZ[key] { return existing }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE MMM d"
        df.timeZone = timezone
        dayHeaderFormattersByTZ[key] = df
        return df
    }

    /// Gregorian calendar cached per TZ. Calendar construction is cheaper
    /// than DateFormatter but the per-TZ cache is in the same shape as the
    /// formatters above, and avoiding per-call construction keeps the
    /// grouping pass allocation-free.
    @MainActor
    static func gregorianCalendar(for timezone: TimeZone) -> Calendar {
        let key = timezone.identifier
        if let existing = calendarsByTZ[key] { return existing }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        calendarsByTZ[key] = calendar
        return calendar
    }

    private func buildRows(
        contacts: [Contact],
        reminders: [ScheduledReminder],
        now: Date
    ) -> [UpcomingRowState] {
        let calendar = Self.gregorianCalendar(for: window.timeZone)
        let horizonEnd = calendar.date(byAdding: .day, value: horizonDays, to: now) ?? now
        var rows: [UpcomingRowState] = []

        for contact in contacts {
            if let cadence = contact.cadenceDays {
                let last = contact.lastInteractedAt ?? contact.createdAt
                let overdueAt = last.addingTimeInterval(TimeInterval(cadence) * 86_400)
                let target = max(now, overdueAt)
                // `nextAllowedSlot` now returns nil for a zero-capacity window
                // (R4). This VM's `.defaultV1()` window always has capacity, so
                // nil never happens today, but skip the row rather than crash if
                // a future override wires a degenerate window through here.
                guard let fires = engine.nextAllowedSlot(
                    from: target,
                    in: window,
                    includingContainingSlot: overdueAt <= now
                ) else { continue }
                // An already-overdue contact inside an active window resolves
                // to that window's slot start for deterministic batching. The
                // slot start can be earlier than `now`; it still represents an
                // immediate reminder and belongs in Upcoming. Future cadence
                // eligibility remains guarded by `nextAllowedSlot` itself.
                if fires < horizonEnd {
                    rows.append(UpcomingRowState(
                        id: .init(contactId: contact.id, kind: .cadence),
                        contactId: contact.id,
                        name: contact.displayName,
                        kind: .cadence,
                        scheduledFor: fires,
                        channel: contact.preferredChannel,
                        cadenceText: CadenceDescriptor.describe(days: cadence),
                        occasionText: nil,
                        timeOfDayText: Self.format(time: fires, timezone: window.timeZone),
                        dayHeader: Self.format(dayHeader: fires, now: now, timezone: window.timeZone)
                    ))
                }
            }
        }

        // Occasion rows are seeded in the Phase 0 mock repository so their
        // birthday/anniversary states remain reachable and auditable. TF-07
        // replaces this bounded fetch with the persisted ValueObservation
        // pipeline that owns every Upcoming row (§14 PR25 / R10).
        let contactsByID = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        let startOfToday = calendar.startOfDay(for: now)
        for reminder in reminders where reminder.kind != .cadence {
            // A morning-of occasion remains actionable for the rest of its
            // local calendar day even after its notification time has passed
            // (§9 contract 4 / R5). Older days and the exclusive horizon end
            // stay out of the forward-looking list.
            guard reminder.scheduledFor >= startOfToday,
                  reminder.scheduledFor < horizonEnd,
                  let contact = contactsByID[reminder.contactId] else { continue }
            let occasionText: String
            if let label = reminder.occasionLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty {
                occasionText = label
            } else {
                occasionText = switch reminder.kind {
                case .birthday: "Birthday"
                case .anniversary: "Anniversary"
                case .customOccasion: "Occasion"
                case .cadence: ""
                }
            }
            rows.append(UpcomingRowState(
                id: .init(
                    contactId: contact.id,
                    kind: reminder.kind,
                    reminderId: reminder.id
                ),
                contactId: contact.id,
                name: contact.displayName,
                kind: reminder.kind,
                scheduledFor: reminder.scheduledFor,
                channel: contact.preferredChannel,
                cadenceText: nil,
                occasionText: occasionText,
                timeOfDayText: Self.format(
                    time: reminder.scheduledFor,
                    timezone: window.timeZone
                ),
                dayHeader: Self.format(
                    dayHeader: reminder.scheduledFor,
                    now: now,
                    timezone: window.timeZone
                )
            ))
        }

        return rows.sorted {
            if $0.scheduledFor != $1.scheduledFor {
                return $0.scheduledFor < $1.scheduledFor
            }
            if $0.contactId != $1.contactId {
                return $0.contactId.uuidString < $1.contactId.uuidString
            }
            if $0.kind != $1.kind {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return ($0.id.reminderId?.uuidString ?? "") < ($1.id.reminderId?.uuidString ?? "")
        }
    }

    private func group(rows: [UpcomingRowState]) -> [(header: String, rows: [UpcomingRowState])] {
        var ordered: [(String, [UpcomingRowState])] = []
        var seen: [String: Int] = [:]
        for row in rows {
            if let idx = seen[row.dayHeader] {
                ordered[idx].1.append(row)
            } else {
                seen[row.dayHeader] = ordered.count
                ordered.append((row.dayHeader, [row]))
            }
        }
        return ordered
    }

    @MainActor
    static func format(time: Date, timezone: TimeZone) -> String {
        timeFormatter(for: timezone).string(from: time).lowercased()
    }

    @MainActor
    static func format(dayHeader date: Date, now: Date, timezone: TimeZone) -> String {
        let calendar = gregorianCalendar(for: timezone)
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let diff = calendar.dateComponents([.day], from: today, to: day).day ?? 0

        let suffix = dayHeaderSuffixFormatter(for: timezone).string(from: date)

        if diff == 0 { return "Today · \(suffix)" }
        if diff == 1 { return "Tomorrow · \(suffix)" }
        return suffix
    }
}
