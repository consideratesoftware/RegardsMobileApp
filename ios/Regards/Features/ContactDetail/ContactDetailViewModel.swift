import Foundation
import Observation

@Observable @MainActor
public final class ContactDetailViewModel {

    public struct InteractionEntry: Sendable, Identifiable, Equatable {
        public let id: UUID
        public let dateLabel: String
        public let descriptionLabel: String

        /// The spoken VoiceOver label for this interaction row, e.g.
        /// "3 days ago, Caught up, WhatsApp".
        ///
        /// The visual `descriptionLabel` separates its parts with a middle
        /// dot; VoiceOver reads that character aloud, so the spoken form
        /// substitutes a comma to get a natural pause instead. This lives on
        /// the entry, not in the view, so it is unit-testable — matching
        /// `UpcomingRowState.accessibilityLabel`.
        public var accessibilityLabel: String {
            let spoken = descriptionLabel.replacingOccurrences(of: " · ", with: ", ")
            guard !spoken.isEmpty else { return dateLabel }
            return "\(dateLabel), \(spoken)"
        }
    }

    public private(set) var contact: Contact?
    public private(set) var interactions: [InteractionEntry] = []

    private let contacts: any ContactRepository
    private let interactionsRepo: any InteractionRepository
    private let scheduler: SchedulingPass
    private let contactId: UUID
    private let clock: () -> Date
    private let calendar: Calendar

    /// `calendar` is injected so tests can pin the day math to a fixed TZ;
    /// see sibling note in `OverdueViewModel` on the intentional
    /// user-local-vs-window-TZ split.
    public init(contactId: UUID,
                contacts: any ContactRepository,
                interactionsRepo: any InteractionRepository,
                scheduler: SchedulingPass,
                clock: @escaping () -> Date = { Date() },
                calendar: Calendar = .current) {
        self.contactId = contactId
        self.contacts = contacts
        self.interactionsRepo = interactionsRepo
        self.scheduler = scheduler
        self.clock = clock
        self.calendar = calendar
    }

    public var contactID: UUID {
        contactId
    }

    public func load() async {
        do {
            contact = try await contacts.fetch(id: contactId)
            let logs = try await interactionsRepo.fetchRecent(forContact: contactId, limit: 8)
            // `logs.map(Self.toEntry)` would pass a `@MainActor`-isolated
            // function reference into `Array.map`'s nonisolated parameter
            // type — Swift 6 strict concurrency rejects it. The `for` loop
            // stays on the enclosing MainActor and calls `toEntry`
            // directly, no isolation crossing.
            var entries: [InteractionEntry] = []
            entries.reserveCapacity(logs.count)
            for log in logs { entries.append(Self.toEntry(log)) }
            interactions = entries
        } catch {
            Self.log.error(
                "failed to load contact \(self.contactId, privacy: .private): \(error, privacy: .private)"
            )
            contact = nil
            interactions = []
        }
    }

    static let log = RegardsLogger.feature("ContactDetail")

    // MARK: - Actions (R11 / PR22)

    /// "Caught up": clears any pending snooze through `SchedulingPass
    /// .caughtUp`, then logs a `.reminderCaughtUp` interaction against the
    /// contact's preferred channel and moves `lastInteractedAt` to now, then
    /// reloads so the interactions list and derived labels reflect it
    /// immediately — see `OverdueViewModel.markCaughtUp`'s doc comment for
    /// why clearing the snooze is required so Overdue/Upcoming don't keep
    /// showing a stale snoozed date.
    ///
    /// `scheduler.caughtUp` runs *before* `InteractionLogging`, not after:
    /// `InteractionLogging`'s `contacts.updateLastInteractedAt` broadcasts
    /// through `observeTracked()` the instant it lands, and a concurrently
    /// observing Overdue/Upcoming view model reloading off that broadcast
    /// would compute its row before the reminder-state write had cleared the
    /// snooze — briefly showing the stale date anyway, even though this
    /// method "already" cleared it moments later. Doing the reminder-state
    /// write first means every broadcast this method can trigger only ever
    /// fires after the snooze is already gone.
    ///
    /// This is still two writes, not one: `scheduler.caughtUp` can succeed
    /// while the later `InteractionLogging` call throws (or partially
    /// applies — it appends the log, then moves `lastInteractedAt`, with no
    /// compensation if the second half fails). Any of those partial
    /// combinations leaves the screen possibly rendering pre-write state —
    /// worse than a clean failure, since nothing here otherwise tells the
    /// user their action actually landed. The catch block reloads
    /// unconditionally (not just on total failure) so the view always ends
    /// up consistent with whatever combination of writes actually persisted,
    /// mirroring why `OverdueViewModel.markCaughtUp`'s catch reloads too.
    ///
    /// Returns whether the write succeeded so `ContactDetailScreen` can gate
    /// its VoiceOver announcement on it — mirrors
    /// `OverdueViewModel.markCaughtUp`'s same-shaped return value and the
    /// same reasoning: announcing "marked caught up" against a write that
    /// then failed would tell a VoiceOver user something that didn't happen.
    @discardableResult
    public func markCaughtUp() async -> Bool {
        let logging = InteractionLogging(contacts: contacts, interactions: interactionsRepo)
        do {
            try await scheduler.caughtUp(contactId: contactId)
            try await logging.markCaughtUp(contactId: contactId, at: clock())
            await load()
            return true
        } catch {
            Self.log.error(
                "failed to mark caught up for \(self.contactId, privacy: .private): \(error, privacy: .private)"
            )
            await load()
            return false
        }
    }

    /// "Log other channel…": the same downstream effect as `markCaughtUp` —
    /// reaching a contact through any channel still counts as staying in
    /// touch — logged as `.manual` against the channel the user actually
    /// used. Clears any pending snooze through `SchedulingPass.caughtUp`
    /// first, exactly like `markCaughtUp` does and for the same
    /// broadcast-ordering reason (see its doc comment): without this call a
    /// snoozed contact logged through another channel would keep showing the
    /// stale snoozed date in Overdue/Upcoming.
    ///
    /// Same reload rationale as `markCaughtUp`: the catch block reloads
    /// unconditionally, not only when every write fails, because
    /// `scheduler.caughtUp` can succeed while the later `InteractionLogging`
    /// call throws or only partially applies — leaving the screen possibly
    /// rendering pre-write state otherwise.
    ///
    /// Returns whether the write succeeded — see `markCaughtUp`'s doc
    /// comment for why the screen needs this.
    @discardableResult
    public func logOther(channel: Channel) async -> Bool {
        let logging = InteractionLogging(contacts: contacts, interactions: interactionsRepo)
        do {
            try await scheduler.caughtUp(contactId: contactId)
            try await logging.logOther(contactId: contactId, channel: channel, at: clock())
            await load()
            return true
        } catch {
            Self.log.error(
                "failed to log other channel for \(self.contactId, privacy: .private): \(error, privacy: .private)"
            )
            await load()
            return false
        }
    }

    /// "Snooze 1 wk": pushes the contact's cadence reminder out 7 days
    /// through `SchedulingPass` (§14 PR22's DB-only stub). No interaction is
    /// logged and `lastInteractedAt` is untouched (decision #31) — this
    /// screen's own labels don't yet read the persisted reminder (TF-07
    /// wires the "live next reminder" placeholder), so there's nothing to
    /// reload here; Overdue and Upcoming pick the change up through their
    /// own reads.
    ///
    /// Returns whether the write succeeded — see `markCaughtUp`'s doc
    /// comment for why the screen needs this.
    @discardableResult
    public func snooze() async -> Bool {
        do {
            try await scheduler.snooze(contactId: contactId)
            return true
        } catch {
            Self.log.error(
                "failed to snooze \(self.contactId, privacy: .private): \(error, privacy: .private)"
            )
            return false
        }
    }

    // MARK: - Formatters (constructed once, locale-pinned)
    //
    // `@MainActor` because `static let` on an `@MainActor` class doesn't
    // inherit the class's actor isolation, and `DateFormatter` isn't
    // Sendable — Swift 6 strict concurrency flags a shared non-Sendable
    // static otherwise. This formatter has no timezone (it's device-local
    // short date), so unlike `UpcomingViewModel` it doesn't need a per-TZ
    // cache — one instance is enough.
    @MainActor
    static let shortDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM d"
        return df
    }()

    @MainActor
    static func toEntry(_ log: InteractionLog) -> InteractionEntry {
        let channel = log.channel?.displayName ?? "Manual"
        let source: String
        switch log.source {
        case .manual:             source = "manual log"
        case .reminderTap:        source = "reminder tap"
        case .reminderCaughtUp:   source = "reminder caught up"
        }
        return InteractionEntry(
            id: log.id,
            dateLabel: shortDateFormatter.string(from: log.occurredAt),
            descriptionLabel: "\(channel) · \(source)"
        )
    }

    // MARK: - Derived strings for the view

    public var priorityLabel: String {
        switch contact?.priorityTier {
        case .innerCircle?:  return "inner circle"
        case .close?:        return "close friend"
        case .regular?:      return "regular"
        case .acquaintance?: return "acquaintance"
        case nil:            return ""
        }
    }

    public var cadenceLabel: String {
        guard let days = contact?.cadenceDays else { return "not tracked" }
        return CadenceDescriptor.describe(days: days)
    }

    public var overdueSummary: (days: Int, isOverdue: Bool) {
        guard let c = contact, let cadence = c.cadenceDays else {
            return (0, false)
        }
        // `?? c.createdAt`, not `lastInteractedAt` alone: the never-contacted
        // anchor (decision #29 / R8) — `OverdueViewModel.makeOverdueRow` and
        // `UpcomingViewModel.buildRows` both fall back to `createdAt` for a
        // tracked contact never yet logged as contacted. Guarding this
        // property on `lastInteractedAt` being non-nil was a third,
        // disagreeing implementation: it reported "on track" for exactly the
        // contacts the other two screens correctly show as overdue.
        let last = c.lastInteractedAt ?? c.createdAt
        let overdueAt = last.addingTimeInterval(TimeInterval(cadence) * 86_400)
        // Calendar-based day delta to honor DST and timezone boundaries.
        let days = calendar.dateComponents([.day], from: overdueAt, to: clock()).day ?? 0
        return (max(0, days), days > 0)
    }

    public var lastTalkedLabel: String {
        guard let last = contact?.lastInteractedAt else { return "never" }
        let rel = Contact.relativeDescription(for: last, from: clock()) ?? "—"
        return "\(rel) · \(Self.shortDateFormatter.string(from: last))"
    }
}
