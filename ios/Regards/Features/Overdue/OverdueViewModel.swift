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
    private let interactions: any InteractionRepository
    private let reminders: any ReminderRepository
    private let scheduler: SchedulingPass
    private let clock: () -> Date
    private let calendar: Calendar
    private var loadGeneration = 0
    private var observationTask: Task<Void, Never>?

    /// `calendar` is injected so tests (and future multi-timezone logic)
    /// can pin the day math to a fixed TZ. Production uses `.current`
    /// (user-local), which drifts from `window.timeZone` when the user
    /// travels — "6d overdue" computed here may disagree by one calendar
    /// day with "fires today" computed against the window's TZ in
    /// `ReminderEngine`. Intentional: the overdue label describes the
    /// user's perception right now, not the scheduling clock.
    public init(contacts: any ContactRepository,
                interactions: any InteractionRepository,
                reminders: any ReminderRepository,
                scheduler: SchedulingPass,
                clock: @escaping () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.contacts = contacts
        self.interactions = interactions
        self.reminders = reminders
        self.scheduler = scheduler
        self.clock = clock
        self.calendar = calendar
    }

    public func load() async {
        await startObservingIfNeeded()
        await performLoad()
    }

    /// Subscribes once to `contacts.observeTracked()` so this screen reflects
    /// an action taken elsewhere — Contact Detail's Caught up / Log other —
    /// without the user having to leave and return (ARCHITECTURE.md §14
    /// PR22: "live lists update"). `load()` can be called again afterward
    /// (pull-to-refresh, retry) without re-subscribing.
    ///
    /// Awaits `observeTracked()` itself (registering the subscription)
    /// before spawning the Task that consumes it. Doing the subscribe inside
    /// the spawned Task instead would race: `Task { ... }` only *schedules*
    /// its body, so a write happening right after `load()` returns could run
    /// before that body ever reaches its `for await`, and the never-replayed
    /// stream (see `ContactRepository.observeTracked()`) would silently miss
    /// it. Subscribing here first, synchronously relative to `load()`'s
    /// caller, means every write after `load()` returns is guaranteed seen.
    ///
    /// `self` is re-checked weakly on every emission, not just once before
    /// the loop starts: capturing `self` non-weakly for the loop's duration
    /// would keep this long-lived subscription alive for as long as the
    /// repository keeps emitting, defeating `[weak self]` entirely.
    private func startObservingIfNeeded() async {
        guard observationTask == nil else { return }
        // A placeholder, set synchronously before the first suspension
        // below: the guard above and this assignment run back-to-back with
        // no `await` between them, so no second concurrent `load()` can slip
        // between "saw nil" and "set it" the way it could when the
        // assignment waited for `observeTracked()` to return. Without this,
        // two `load()` calls racing at launch (or a fast pull-to-refresh
        // right after) could both see `nil`, both subscribe, and leave one
        // subscription's `Task` orphaned in `observationTask`'s overwrite —
        // never cancelled, running for the screen's entire lifetime.
        observationTask = Task {}
        let updates = await contacts.observeTracked()
        observationTask = Task { [weak self] in
            for await _ in updates {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.performLoad()
            }
        }
    }

    private func performLoad() async {
        loadGeneration += 1
        let generation = loadGeneration
        if loadState != .loaded {
            loadState = .loading
        }
        do {
            let all = try await contacts.fetchTracked()
            // A pending cadence reminder is Snooze's only persisted trace
            // (§14 PR22's `SchedulingPass` stub) — no separate "snoozed"
            // flag exists on `Contact`. Building the lookup here, once per
            // load, keeps `makeOverdueRow` a pure function of its inputs.
            let snoozedUntilByContact = try await Self.snoozedUntilByContact(reminders: reminders)
            let now = clock()
            let loadedRows = all.compactMap {
                Self.makeOverdueRow(
                    for: $0,
                    now: now,
                    calendar: calendar,
                    snoozedUntil: snoozedUntilByContact[$0.id]
                )
            }
                .filter { $0.overdueDays > 0 }
                .sorted {
                    if $0.priority.rawValue != $1.priority.rawValue {
                        return $0.priority.rawValue < $1.priority.rawValue
                    }
                    return $0.overdueDays > $1.overdueDays
                }
            guard generation == loadGeneration else { return }
            rows = loadedRows
            loadState = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            Self.log.error("failed to load tracked contacts: \(error, privacy: .private)")
            rows = []
            loadState = .failed
        }
    }

    private static func snoozedUntilByContact(
        reminders: any ReminderRepository
    ) async throws -> [UUID: Date] {
        let pendingCadence = try await reminders.fetchAllPending().filter { $0.kind == .cadence }
        return Dictionary(
            pendingCadence.map { ($0.contactId, $0.scheduledFor) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// "Caught up" from an Overdue row: logs the interaction and moves
    /// `lastInteractedAt`, then removes the row from view immediately rather
    /// than waiting for the next full `load()` — the acceptance contract for
    /// this action is that it moves the contact out of Overdue instantly
    /// (§14 PR22). A failure restores the true state with a fresh `load()`
    /// instead of re-inserting the row locally, so the list never disagrees
    /// with what is actually persisted.
    ///
    /// Returns whether the write succeeded so the screen can gate its
    /// VoiceOver announcement on it — announcing "marked caught up" against
    /// a write that then fails and reloads the row back in would tell a
    /// VoiceOver user something that didn't happen.
    @discardableResult
    public func markCaughtUp(contactId: UUID) async -> Bool {
        rows.removeAll { $0.contactId == contactId }
        let logging = InteractionLogging(contacts: contacts, interactions: interactions)
        do {
            try await logging.markCaughtUp(contactId: contactId, at: clock())
            return true
        } catch {
            Self.log.error(
                "failed to mark caught up for \(contactId, privacy: .private): \(error, privacy: .private)"
            )
            await performLoad()
            return false
        }
    }

    /// "Snooze 1 wk" from an Overdue row: pushes the contact's cadence
    /// reminder 7 days out through `SchedulingPass` (§14 PR22's DB-only
    /// stub) and removes the row from view immediately, mirroring
    /// `markCaughtUp`'s instant-removal contract. No interaction is logged
    /// and `lastInteractedAt` is untouched (decision #31).
    ///
    /// Returns whether the write succeeded — see `markCaughtUp`'s doc
    /// comment for why the caller needs this.
    @discardableResult
    public func snooze(contactId: UUID) async -> Bool {
        rows.removeAll { $0.contactId == contactId }
        do {
            try await scheduler.snooze(contactId: contactId)
            return true
        } catch {
            Self.log.error(
                "failed to snooze \(contactId, privacy: .private): \(error, privacy: .private)"
            )
            await performLoad()
            return false
        }
    }

    public var innerCircleRows: [OverdueRowState] { rows.filter { $0.priority == .innerCircle } }
    public var closeFriendRows: [OverdueRowState] { rows.filter { $0.priority == .close } }
    public var otherRows: [OverdueRowState] {
        rows.filter { $0.priority == .regular || $0.priority == .acquaintance }
    }

    public var overdueCount: Int { rows.count }

    static let log = RegardsLogger.feature("Overdue")

    /// `snoozedUntil` is the contact's pending cadence `ScheduledReminder`'s
    /// `scheduledFor`, if one exists (§14 PR22's `SchedulingPass.snooze`
    /// stub) — `nil` for a never-snoozed contact. While it's still in the
    /// future the contact is suppressed from Overdue entirely, regardless of
    /// how overdue the raw cadence math says it is; once it lapses, this
    /// falls through to the ordinary `lastInteractedAt`-based computation
    /// unchanged, so the row "returns" on its own the next time this runs
    /// after the snoozed date passes.
    static func makeOverdueRow(for contact: Contact,
                               now: Date,
                               calendar: Calendar,
                               snoozedUntil: Date? = nil) -> OverdueRowState? {
        guard contact.tracked, let cadenceDays = contact.cadenceDays else { return nil }
        if let snoozedUntil, snoozedUntil > now { return nil }
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
            overdueDays: overdueDays,
            isVirtualMerged: contact.contactGroupId != nil
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
