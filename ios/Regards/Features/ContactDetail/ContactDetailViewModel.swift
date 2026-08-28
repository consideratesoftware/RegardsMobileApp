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
    /// The contact's pending cadence reminder's `scheduledFor`, refreshed on
    /// every `load()` — R56's fix (ARCHITECTURE.md). `nil` when nothing is
    /// pending. Read through `scheduler.pendingSnoozeDate(contactId:)`
    /// rather than a `ReminderRepository` of this view model's own; see that
    /// method's doc comment for why. `overdueSummary` below is the only
    /// current reader.
    public private(set) var pendingSnoozeDate: Date?

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

    /// Bumped on every `load()`; a load whose generation is stale by the
    /// time it resumes discards its results rather than overwriting a
    /// newer one's. Mirrors the two list view models.
    private var loadGeneration = 0

    public func load() async {
        // Same generation guard `OverdueViewModel.performLoad` and
        // `UpcomingViewModel.performLoad` carry, and for the same reason —
        // this screen was the one sibling that never got it (staged review
        // round 20). Every PR22 action here (`markCaughtUp`, `logOther`,
        // `snooze`) fires its own untracked `Task` ending in a second
        // `load()`, and nothing disables the buttons in between, so two
        // loads overlap readily. Without this, a stale load that started
        // first but finished last overwrites the newer one's state — worst
        // through the `catch` below, which nils `contact` outright and would
        // flash "N days overdue" back onto a screen whose action had just
        // succeeded. Exactly the false-success class R56 fixed for
        // `overdueSummary`.
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let fetched = try await contacts.fetch(id: contactId)
            guard generation == loadGeneration else { return }
            contact = fetched
            let logs = try await interactionsRepo.fetchRecent(forContact: contactId, limit: 8)
            guard generation == loadGeneration else { return }
            // `logs.map(Self.toEntry)` would pass a `@MainActor`-isolated
            // function reference into `Array.map`'s nonisolated parameter
            // type — Swift 6 strict concurrency rejects it. The `for` loop
            // stays on the enclosing MainActor and calls `toEntry`
            // directly, no isolation crossing.
            var entries: [InteractionEntry] = []
            entries.reserveCapacity(logs.count)
            for log in logs { entries.append(Self.toEntry(log)) }
            interactions = entries
            // A failed snooze lookup degrades to "nothing known pending"
            // instead of failing the whole load (R56) — mirrors
            // `OverdueViewModel.performLoad`'s identical tolerance for its
            // own `fetchAllPending()` read: `contact`/`interactions` above
            // already succeeded, so losing only the snooze lookup is far
            // less harmful than blanking the screen over it.
            do {
                let pending = try await scheduler.pendingSnoozeDate(contactId: contactId)
                guard generation == loadGeneration else { return }
                pendingSnoozeDate = pending
            } catch {
                guard generation == loadGeneration else { return }
                Self.log.error(
                    "failed to load snooze for \(self.contactId, privacy: .private): \(error, privacy: .private)"
                )
                pendingSnoozeDate = nil
            }
        } catch {
            guard generation == loadGeneration else { return }
            Self.log.error(
                "failed to load contact \(self.contactId, privacy: .private): \(error, privacy: .private)"
            )
            contact = nil
            interactions = []
            pendingSnoozeDate = nil
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
    ///
    /// The catch block also restores a snooze `scheduler.caughtUp` genuinely
    /// cleared before `InteractionLogging` then failed (staged review round
    /// 7): without this, a failed Caught up silently destroyed an existing
    /// snooze — the user heard only "Couldn't mark X caught up," with
    /// nothing about the reload above restoring the reminder their earlier
    /// Snooze tap had set. See `SchedulingPass.restorePendingAfterFailedCaughtUp`'s
    /// doc comment for why this reverts the same row rather than fabricating
    /// a fresh date via a second `snooze()` call.
    @discardableResult
    public func markCaughtUp() async -> Bool {
        let logging = InteractionLogging(contacts: contacts, interactions: interactionsRepo)
        var clearedPendingSnooze = false
        do {
            clearedPendingSnooze = try await scheduler.caughtUp(contactId: contactId)
            try await logging.markCaughtUp(contactId: contactId, at: clock())
            await load()
            return true
        } catch {
            Self.log.error(
                "failed to mark caught up for \(self.contactId, privacy: .private): \(error, privacy: .private)"
            )
            if clearedPendingSnooze {
                await restorePendingSnooze()
            }
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
    /// comment for why the screen needs this, and for why the catch block
    /// also restores a snooze `scheduler.caughtUp` genuinely cleared.
    @discardableResult
    public func logOther(channel: Channel) async -> Bool {
        let logging = InteractionLogging(contacts: contacts, interactions: interactionsRepo)
        var clearedPendingSnooze = false
        do {
            clearedPendingSnooze = try await scheduler.caughtUp(contactId: contactId)
            try await logging.logOther(contactId: contactId, channel: channel, at: clock())
            await load()
            return true
        } catch {
            Self.log.error(
                "failed to log other channel for \(self.contactId, privacy: .private): \(error, privacy: .private)"
            )
            if clearedPendingSnooze {
                await restorePendingSnooze()
            }
            await load()
            return false
        }
    }

    /// Shared by `markCaughtUp` and `logOther` above. Logs its own failure
    /// separately from the caller's: a failure here means the user's snooze
    /// is genuinely lost, not merely that this method didn't get to try —
    /// worth its own diagnostic line rather than folding into the outer
    /// catch's message.
    private func restorePendingSnooze() async {
        do {
            try await scheduler.restorePendingAfterFailedCaughtUp(contactId: contactId)
        } catch {
            Self.log.error(
                "failed to restore snooze for \(self.contactId, privacy: .private): \(error, privacy: .private)"
            )
        }
    }

    /// "Snooze 1 wk": pushes the contact's cadence reminder out 7 days
    /// through `SchedulingPass` (§14 PR22's DB-only stub). No interaction is
    /// logged and `lastInteractedAt` is untouched (decision #31).
    ///
    /// Reloads on success (R56 fix, staged review): `load()` now also reads
    /// `pendingSnoozeDate`, which `overdueSummary` consults to suppress
    /// overdue state while the snooze is still pending — without a reload
    /// here, the screen kept reading "N days overdue" from the pre-snooze
    /// snapshot until some *unrelated* trigger (a tab switch, a pop/push)
    /// happened to reload it. `nextReminderLabel`'s own hardcoded
    /// placeholder is a separate, still-open gap (R11) this reload does not
    /// touch. Most other screen labels (`cadenceLabel`, `lastTalkedLabel`)
    /// are untouched by a snooze and simply re-derive the same values.
    ///
    /// Returns whether the write succeeded — see `markCaughtUp`'s doc
    /// comment for why the screen needs this.
    ///
    /// Gated on `contact.isActive` (staged review round 7): `load()` fetches
    /// through `contacts.fetch(id:)`, which — unlike `fetchTracked()` —
    /// doesn't filter `archivedAt`, so a contact this screen already has
    /// open can be archived out from under it by a concurrent
    /// `ContactsReconciler` pass mid-session, with Snooze staying tappable.
    /// `SchedulingPass.snooze` itself has no such check (R54: it writes for
    /// any contact that merely exists), so without this guard the write
    /// would still land — a pending cadence row that no `fetchTracked()`
    /// screen (Overdue, Upcoming) will ever surface, orphaned until PR25
    /// gives the scheduler its own precondition.
    ///
    /// Re-fetches rather than checking the cached `self.contact` (staged
    /// review round 10, fixing what round 7 shipped): `self.contact` is a
    /// snapshot from the *last* `load()`, so checking it instead of a fresh
    /// read left exactly the race this guard exists to close — a contact
    /// archived after this screen's `load()` but before this tap still
    /// read as active from the stale snapshot and got a snooze written
    /// anyway. `OverdueViewModel.snooze` re-fetches for the identical
    /// reason; this now matches it. A failed re-fetch is treated the same
    /// as "inactive" — there's nothing else safe to do with an unreadable
    /// precondition — but logged distinctly so it doesn't read as a silent
    /// no-op.
    @discardableResult
    public func snooze() async -> Bool {
        let freshContact: Contact?
        do {
            freshContact = try await contacts.fetch(id: contactId)
        } catch {
            Self.log.error(
                "failed to verify \(self.contactId, privacy: .private) is active: \(error, privacy: .private)"
            )
            freshContact = nil
        }
        guard let freshContact, freshContact.isActive else { return false }
        do {
            // `SchedulingPass.snooze` now carries its own tracked/cadence
            // precondition (R54) — the `isActive` guard above stays because
            // it catches something that precondition doesn't (an
            // archived-after-`load()` race), not because it's redundant
            // with it. `wrote` should always be `true` here today: this
            // screen only ever offers Snooze for a contact whose row is
            // already computed as overdue, which requires tracked +
            // cadenceDays by construction. Propagated rather than assumed,
            // so a future caller that reaches this method some other way
            // gets an honest `false`, not a lie.
            let wrote = try await scheduler.snooze(contactId: contactId)
            if wrote { await load() }
            return wrote
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

    /// Folds in a pending snooze (R56 fix, promoted from deferred at staged
    /// review): previously computed purely from `Contact`'s own fields —
    /// `cadenceDays`, `lastInteractedAt`, `createdAt` — with no read of any
    /// pending `ScheduledReminder`, so right after a successful Snooze this
    /// kept reporting "N days overdue" against stale cadence math — a
    /// user-visible false statement on the success path. VoiceOver already
    /// stopped announcing it (by not moving focus there), which suppressed
    /// the symptom for that one audience and left a sighted user reading
    /// something false; this closes it for both. Mirrors
    /// `OverdueViewModel.makeOverdueRow`'s identical guard: a pending snooze
    /// still in the future suppresses overdue state entirely, not just
    /// trims the day count. `pendingSnoozeDate` is refreshed by `load()`
    /// through `scheduler.pendingSnoozeDate(contactId:)` — see that
    /// property's own doc comment for why this didn't need TF-07/PR25's
    /// full `ReminderRepository` wiring after all.
    public var overdueSummary: (days: Int, isOverdue: Bool) {
        // `c.tracked &&`, not `cadenceDays` alone (nit, staged review round
        // 9): `OverdueViewModel.makeOverdueRow` and this screen's own Snooze
        // button (`secondaryItems`) both gate on `tracked && cadenceDays !=
        // nil` — a fourth, narrower spelling of the same predicate here
        // wasn't wrong (an untracked contact can't currently carry a
        // `cadenceDays`), just inconsistent with the other two.
        guard let c = contact, c.tracked, let cadence = c.cadenceDays else {
            return (0, false)
        }
        // Mirrors `OverdueViewModel.makeOverdueRow`'s `if let snoozedUntil,
        // snoozedUntil > now { return nil }` — a pending-and-future snooze
        // means the contact is not overdue *right now*, full stop, not
        // merely "overdue by fewer days than the stale cadence math says."
        if let pendingSnoozeDate, pendingSnoozeDate > clock() {
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
