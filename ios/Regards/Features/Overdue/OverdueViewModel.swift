import Foundation
import Observation

/// Shape the view renders per contact — precomputed in the view model so the
/// view body stays formatting-free.
///
/// No `isVirtualMerged` field (staged review round 11, removed): the "merged"
/// chip it drove sat inside the name's `HStack` and took width directly from
/// the contact name it was competing with — the reason a merged contact's
/// row was the worst-affected by the row-crowding bug a device screenshot
/// caught. Sid decided merge provenance belongs on Merge Duplicates alone,
/// where a user can actually act on it, not surfaced passively on a screen
/// that never asked them to. `isVirtualMerged` only ever rendered here in
/// the first place — never on Contacts, Upcoming, or Contact Detail — which
/// in hindsight reads as the spec's row description being wrong (it listed
/// this chip), not the other three screens missing a feature.
///
/// No `cadenceText`/`lastInteractedText` fields either (same round): the
/// visible metadata line and the spoken label both dropped cadence and
/// last-contacted down to just `overdueDays` (Sid's words: "Just have name
/// and how much overdue"), and neither field had any other reader once
/// `OverdueRow.metadataString` stopped using them — see that computed
/// property's own doc comment for the full reasoning.
public struct OverdueRowState: Sendable, Identifiable, Equatable {
    public var id: UUID { contactId }
    public let contactId: UUID
    public let name: String
    public let priority: PriorityTier
    public let overdueDays: Int
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
    private(set) var loadState: RegardsLoadState = .loading

    private let contacts: any ContactRepository
    // Unused since TF-07d (the pass logs interactions); TF-07f removes it.
    private let interactions: any InteractionRepository
    private let reminders: any ReminderRepository
    private let scheduler: SchedulingPass
    private let clock: () -> Date
    private let calendar: Calendar
    private var loadGeneration = 0
    // `ObservationSubscriptionToken`, not a plain `Task<Void, Never>?`
    // stored property (staged review round 10 coverage gap; see that
    // type's own doc comment for the full reasoning): a `deinit` directly
    // on this `@MainActor` class can't cancel a plain stored property —
    // `deinit` is itself nonisolated in this language mode, and
    // `nonisolated` cannot be applied to a mutable stored property to
    // bridge that gap. Delegating ownership to this ordinary reference
    // type's own `deinit` ends the subscription deterministically when
    // this view model deallocates, instead of only on the underlying
    // stream's next emission (which may never come).
    private let observationTaskToken = ObservationSubscriptionToken()

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
        guard observationTaskToken.task == nil else { return }
        // A placeholder, set synchronously before the first suspension
        // below: the guard above and this assignment run back-to-back with
        // no `await` between them, so no second concurrent `load()` can slip
        // between "saw nil" and "set it" the way it could when the
        // assignment waited for `observeTracked()` to return. Without this,
        // two `load()` calls racing at launch (or a fast pull-to-refresh
        // right after) could both see `nil`, both subscribe, and leave one
        // subscription's `Task` orphaned in the token's overwrite — never
        // cancelled, running for the screen's entire lifetime.
        observationTaskToken.task = Task {}
        let updates = await contacts.observeTracked()
        observationTaskToken.task = Task { [weak self] in
            for await _ in updates {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.performLoad()
            }
            // The stream ended on its own — GRDB's `onError` finished it, or
            // the mock's subscription was torn down — without this Task
            // itself being cancelled. Leaving the token's task set would
            // make every future `load()`'s `guard ... == nil` find a
            // non-nil but permanently-dead Task and skip re-subscribing
            // forever: live cross-screen updates gone for the rest of the
            // process, with nothing surfacing that anywhere. Clearing it
            // here lets the next `load()` open a fresh one.
            guard let self, !Task.isCancelled else { return }
            self.observationTaskToken.task = nil
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
            // Building this here, once per load, keeps `makeOverdueRow` a
            // pure function of its inputs.
            //
            // A failed `fetchAllPending()` degrades to "no snoozes known"
            // instead of propagating and blanking the whole screen: `all`
            // above already succeeded, so the only thing actually missing is
            // which contacts are snoozed, and losing that temporarily is far
            // less harmful than losing every row (R50 reasoning — same
            // per-row/per-field tolerance as `observeTracked()`'s
            // `compactMap` fix, applied here to a read scoped to one lookup
            // rather than the whole load).
            let pendingReminders: [ScheduledReminder]
            do {
                pendingReminders = try await reminders.fetchAllPending()
            } catch {
                Self.log.error("failed to load pending reminders for snooze lookup: \(error, privacy: .private)")
                pendingReminders = []
            }
            // A snoozed contact's pending cadence reminder's `scheduledFor`
            // (the floor resolved into the window, §9), keyed by contact id.
            // Only a row with a floor is a snooze: SchedulingPass also writes
            // a plain pending row for every eligible contact, and that one
            // must not hide an overdue contact. Inlined rather than a shared
            // `PendingSnoozeLookup` helper: two call sites, below §17's
            // abstraction floor of three. `UpcomingViewModel.buildRows` has its
            // own identical copy.
            let snoozedUntilByContact = Dictionary(
                pendingReminders
                    .filter { $0.kind == .cadence && $0.snoozedUntil != nil }
                    .map { ($0.contactId, $0.scheduledFor) },
                // `max($0, $1)`, not "whichever comes last in the array": two
                // pending cadence rows for one contact shouldn't happen (the
                // deterministic `SchedulingPass.reminderID(contactId:kind:)`
                // write path keeps it to one), but if it ever did, picking by
                // array order would make the winner depend on fetch ordering
                // rather than on which row is actually later — `max` is
                // correct regardless of order.
                uniquingKeysWith: { max($0, $1) }
            )
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
    ///
    /// The writes (clearing any snooze, the interaction, the reschedule) are
    /// one `SchedulingPass.recordInteraction` call; its doc has the ordering
    /// and the restore on failure.
    @discardableResult
    public func markCaughtUp(contactId: UUID) async -> Bool {
        // Bumped synchronously with the optimistic mutation below, not left
        // to `performLoad()` alone: a `load()` already in flight when this
        // is called has already captured its own `generation` and is
        // awaiting a suspension point. Without this bump, that stale load
        // can still finish afterward, pass `guard generation ==
        // loadGeneration` (nothing here would have changed it), and
        // overwrite this method's optimistic removal with its own
        // pre-action row set — the contact reappears. Bumping here
        // invalidates that in-flight load the same way a genuine
        // `performLoad()` call would.
        loadGeneration += 1
        rows.removeAll { $0.contactId == contactId }
        do {
            try await scheduler.recordInteraction(contactId: contactId, .caughtUp)
            // Reload on success too, matching `UpcomingViewModel
            // .markCaughtUp` — which already did, and is why this bug was
            // only ever reachable here (staged review round 19). The
            // generation bump above only invalidates a load already in
            // flight *at that moment*; a load starting after it carries a
            // newer generation and applies legitimately, and if its own
            // fetch resolved before the write below committed, it re-adds
            // the row from pre-action state. With no reload on this path
            // nothing ever corrected that, leaving the contact stuck in
            // Overdue for the rest of the session.
            await performLoad()
            return true
        } catch {
            Self.log.error(
                "failed to mark caught up for \(contactId, privacy: .private): \(error, privacy: .private)"
            )
            await performLoad()
            return false
        }
    }

    /// "Snooze <name> 1 week" from an Overdue row: pushes the contact's cadence
    /// reminder to the first window slot at least 7 days out through
    /// `SchedulingPass` and removes the row from view immediately, mirroring
    /// `markCaughtUp`'s instant-removal contract. No interaction is logged
    /// and `lastInteractedAt` is untouched (decision #31).
    ///
    /// Returns whether the write succeeded — see `markCaughtUp`'s doc
    /// comment for why the caller needs this.
    ///
    /// Same `loadGeneration` bump as `markCaughtUp`, and it matters even
    /// more here: this method's success path never calls `performLoad()` —
    /// a snoozed contact needs no fresh row data, only removal — so there is
    /// no later reload to self-heal a stale one overwriting this row back
    /// in. Without the bump, a `load()` in flight at the moment of the tap
    /// would leave the contact sitting in Overdue after a successful snooze,
    /// visibly failing §14 PR22's "moves the contact out of Overdue
    /// instantly" contract.
    ///
    /// Gated on a fresh `contact.isActive` read (staged review round 8,
    /// same fix `ContactDetailViewModel.snooze` already got in round 7 for
    /// the identical race): a row on screen reflects the *last* `load()`,
    /// not this instant, so a contact a concurrent `ContactsReconciler` pass
    /// archived after that load can still be tapped here before its own
    /// `observeTracked()` broadcast reaches this screen.
    /// `SchedulingPass.snooze` now carries its own tracked/cadence
    /// precondition (R54, closed at the write — see that type's own doc
    /// comment) — this `isActive` guard stays because it catches something
    /// that precondition doesn't (an archived-after-`load()` race), not
    /// because it's redundant with it. Re-fetches rather than trusting the
    /// row's own staleness, since `rows` carries no `archivedAt` of its own
    /// to check. A failed fetch here is treated the same as "inactive" —
    /// there's nothing else safe to do with an unreadable precondition —
    /// but is logged distinctly so it doesn't read as a silent no-op in the
    /// logs.
    @discardableResult
    public func snooze(contactId: UUID) async -> Bool {
        let contact: Contact?
        do {
            contact = try await contacts.fetch(id: contactId)
        } catch {
            Self.log.error("failed to verify \(contactId, privacy: .private) is active: \(error, privacy: .private)")
            contact = nil
        }
        guard let contact, contact.isActive else { return false }
        loadGeneration += 1
        rows.removeAll { $0.contactId == contactId }
        do {
            // `wrote` should always be `true` here today — this screen only
            // ever offers Snooze for a row already computed as overdue,
            // which requires `isCadenceEligible` by construction — but
            // treated the same as a thrown failure when it isn't: the
            // optimistic removal above needs undoing either way, not just
            // on a genuine write error.
            let wrote = try await scheduler.snooze(contactId: contactId)
            if !wrote {
                Self.log.error("snooze rejected for \(contactId, privacy: .private): contact not eligible")
            }
            // Unconditional, where this used to reload only on rejection:
            // the success path has the same staleness hole (staged review
            // round 19, and see `markCaughtUp` above for the mechanism).
            // `SchedulingPass`'s one shared FIFO lock (R59) widens the window
            // by letting the write queue behind any other mutation, so a
            // reload has longer to resolve against pre-write state.
            await performLoad()
            return wrote
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

    /// `snoozedUntil` is the snoozed contact's pending cadence row's
    /// `scheduledFor`: the snooze floor already resolved into the contact's
    /// effective window by `SchedulingPass` (§9, R57's write half). `nil` for
    /// a contact with no snooze. While it's in the future the contact is
    /// suppressed from Overdue regardless of the cadence math; once it
    /// passes, the ordinary `lastInteractedAt` computation decides again.
    /// Upcoming resolves the same stored slot to the same instant, so the two
    /// screens agree on when a snooze lapses.
    static func makeOverdueRow(for contact: Contact,
                               now: Date,
                               calendar: Calendar,
                               snoozedUntil: Date? = nil) -> OverdueRowState? {
        guard contact.isCadenceEligible, let cadenceDays = contact.cadenceDays else { return nil }
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
            isOverdue: overdueDays > 0,
            overdueDays: overdueDays
        )

        return OverdueRowState(
            contactId: contact.id,
            name: contact.displayName,
            priority: contact.priorityTier,
            overdueDays: overdueDays,
            channel: contact.preferredChannel,
            channelLabel: contact.preferredChannel.displayName,
            channelValue: contact.preferredChannelValue,
            accessibilityLabel: contact.accessibilityLabel(context: context)
        )
    }
}
