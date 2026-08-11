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

    /// The spoken VoiceOver label for this row, e.g.
    /// "Leia Organa, Jedi Order anniversary at 6:00 pm". Lives on the state,
    /// not the view, so it's unit-testable: the row previously interpolated
    /// `kind` directly and VoiceOver read the raw enum case name
    /// ("customOccasion") instead of the occasion's label. Cadence rows
    /// speak their cadence text; every other kind speaks its occasion text.
    /// A row with neither omits the phrase rather than speaking empty.
    public var accessibilityLabel: String {
        let what = kind == .cadence ? cadenceText : occasionText
        guard let what, !what.isEmpty else {
            return "\(name) at \(timeOfDayText)"
        }
        return "\(name), \(what) at \(timeOfDayText)"
    }
}

@Observable @MainActor
public final class UpcomingViewModel {

    public private(set) var groups: [(header: String, rows: [UpcomingRowState])] = []
    public private(set) var totalCount: Int = 0
    private(set) var loadState: RegardsLoadState = .loading

    public let horizonDays: Int

    /// The row that owns the zoom-transition source for each contact.
    ///
    /// `matchedTransitionSource` pairs a source with a destination by id, and
    /// Contact Detail's destination is keyed by contact — so the source id has
    /// to be the contact's. A contact can hold both a cadence row and an
    /// occasion row inside the horizon (the §9 contract-6 deviation below), so
    /// without electing an owner the same id is declared twice in one
    /// namespace and the zoom animates from an arbitrary row. The first row
    /// per contact in display order wins.
    public var transitionSourceRowIDs: Set<UpcomingRowState.RowID> {
        var seenContacts: Set<UUID> = []
        var owners: Set<UpcomingRowState.RowID> = []
        for row in groups.flatMap(\.rows) where seenContacts.insert(row.contactId).inserted {
            owners.insert(row.id)
        }
        return owners
    }

    private let contacts: any ContactRepository
    private let reminders: (any ReminderRepository)?
    private let scheduler: SchedulingPass
    private let interactions: any InteractionRepository
    private let engine: ReminderEngine
    private let window: ReminderWindow
    private let clock: () -> Date
    private var loadGeneration = 0
    private var observationTask: Task<Void, Never>?

    /// `reminders`, `scheduler`, and `window` are deliberately undefaulted.
    ///
    /// A defaulted `window` is exactly how R9 shipped: a call site that forgot
    /// to inject the persisted window silently fell back to `.defaultV1()` and
    /// the reminder-window feature became fiction on screen with nothing
    /// failing. A defaulted `reminders` would drop every persisted occasion
    /// just as quietly, and a defaulted `scheduler` would construct one over a
    /// throwaway store disconnected from `reminders` above, silently breaking
    /// the caught-up-clears-snooze fix below. Requiring all three makes a
    /// missed injection a compile error instead of a screen that lies.
    public init(contacts: any ContactRepository,
                reminders: (any ReminderRepository)?,
                scheduler: SchedulingPass,
                interactions: any InteractionRepository,
                engine: ReminderEngine = ReminderEngine(),
                window: ReminderWindow,
                clock: @escaping () -> Date = { Date() }) {
        self.contacts = contacts
        self.reminders = reminders
        self.scheduler = scheduler
        self.interactions = interactions
        self.engine = engine
        self.window = window
        self.horizonDays = window.digestHorizonDays
        self.clock = clock
    }

    public func load() async {
        await startObservingIfNeeded()
        await performLoad()
    }

    /// Subscribes once to `contacts.observeTracked()` so this screen reflects
    /// an action taken elsewhere — Contact Detail's Caught up / Log other, or
    /// Overdue's own row action — without leaving and returning
    /// (ARCHITECTURE.md §14 PR22: "live lists update"). `load()` can be
    /// called again afterward (pull-to-refresh, retry) without
    /// re-subscribing. Scoped to `Contact` changes only: occasion rows still
    /// come from the on-the-fly `reminders.fetchAllPending()` read until
    /// TF-07's `ScheduledReminder ⋈ Contact` pipeline exists (R10).
    ///
    /// Awaits `observeTracked()` itself before spawning the Task that
    /// consumes it — see `OverdueViewModel`'s sibling method for why
    /// subscribing inside the spawned Task would race a write landing right
    /// after `load()` returns. `self` is re-checked weakly on every
    /// emission, not just once before the loop starts, since capturing it
    /// non-weakly would keep this subscription alive indefinitely.
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
            // See `OverdueViewModel.startObservingIfNeeded`'s sibling comment:
            // the stream ending without this Task being cancelled must clear
            // `observationTask` too, or `load()` never re-subscribes.
            guard let self, !Task.isCancelled else { return }
            self.observationTask = nil
        }
    }

    private func performLoad() async {
        loadGeneration += 1
        let generation = loadGeneration
        if loadState != .loaded {
            loadState = .loading
        }
        do {
            // Two independent awaits, deliberately not a consistent snapshot.
            // A write landing between them can produce a list built from a
            // tracked set and a reminder set taken microseconds apart — a
            // contact untracked in that gap keeps its occasion row for one
            // render. The accepted staleness is bounded by the next `load()`,
            // and every mutation path already triggers one, so the window is
            // one frame and self-healing rather than persistent.
            //
            // The invariant TF-07's `ValueObservation` swap must preserve: a
            // row may only appear for a contact present in the same read's
            // tracked set (`contactsByID` below enforces it), and no partially
            // applied write may ever be rendered as a stable state. A single
            // observation over the joined query satisfies both by
            // construction; anything that reintroduces two reads must keep the
            // filter on the join, not on the reminder set alone.
            let tracked = try await contacts.fetchTracked()
            // A failed `fetchAllPending()` degrades to "no snoozes or
            // occasions from reminders known" instead of propagating and
            // blanking the whole screen — mirrors
            // `OverdueViewModel.performLoad()`'s same-shaped fallback (R50
            // reasoning: `tracked` above already succeeded, so the only
            // thing actually missing is the reminder-derived half of a row).
            // Consistency fix, staged review round 6: this used to fail the
            // whole load while Overdue degraded, so one repository error
            // produced two different screens.
            let pendingReminders: [ScheduledReminder]
            do {
                pendingReminders = try await reminders?.fetchAllPending() ?? []
            } catch {
                Self.log.error("failed to load pending reminders for upcoming rows: \(error, privacy: .private)")
                pendingReminders = []
            }
            let now = clock()
            let rows = buildRows(contacts: tracked, reminders: pendingReminders, now: now)
            guard generation == loadGeneration else { return }
            totalCount = rows.count
            groups = group(rows: rows)
            loadState = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            Self.log.error("failed to load upcoming reminders: \(error, privacy: .private)")
            groups = []
            totalCount = 0
            loadState = .failed
        }
    }

    static let log = RegardsLogger.feature("Upcoming")

    /// "Mark caught up" from an Upcoming row: logs the interaction and moves
    /// `lastInteractedAt`, then removes only the contact's *cadence* row from
    /// view immediately rather than waiting for the next full `load()`
    /// (mirrors `OverdueViewModel.markCaughtUp`). An occasion row (birthday,
    /// anniversary) for the same contact is left alone: §9 contract 6 gives
    /// occasions precedence over a same-day cadence reminder, and
    /// `InteractionLogging.markCaughtUp` never touches occasion
    /// `ScheduledReminder` rows, so removing an occasion row here would show
    /// state this action didn't actually produce. A failure restores the
    /// true state with a fresh `load()` instead of re-inserting rows locally.
    ///
    /// Returns whether the write succeeded so the screen can gate its
    /// VoiceOver announcement on it — mirrors `OverdueViewModel.markCaughtUp`.
    ///
    /// Also clears any pending snooze through `SchedulingPass.caughtUp`
    /// *before* the interaction log runs — see `OverdueViewModel.markCaughtUp`'s
    /// doc comment for why: without it a short-cadence contact's stale
    /// snoozed date keeps winning `buildRows`'
    /// `max(now, overdueAt, snoozedUntil)` over the freshly computed one.
    ///
    /// Reloads explicitly on success too, unlike `OverdueViewModel`: the
    /// optimistic update above only *removes* the cadence row, but a
    /// freshly caught-up contact can legitimately owe a *new* one inside
    /// the horizon — Overdue skips this since its `overdueDays` is always 0
    /// once caught up. This reload also used to be the only fix for a
    /// stale-snooze race the write-order change above now closes at the
    /// source, so it stays for the "new row owed" case only.
    ///
    /// `loadGeneration` is bumped synchronously with the optimistic mutation
    /// below, mirroring `OverdueViewModel.markCaughtUp` — a `load()` already
    /// in flight when this is called has captured its own `generation`, and
    /// without this bump it could finish afterward and overwrite the
    /// optimistic removal with stale, pre-action rows. The explicit
    /// `performLoad()` on success below masks the race most of the time
    /// (correct data lands moments later), but the stale row can still
    /// flash back for a frame before that happens.
    ///
    /// The catch block also restores a snooze `scheduler.caughtUp` genuinely
    /// cleared before `InteractionLogging` then failed (staged review round
    /// 7) — see `OverdueViewModel.markCaughtUp`'s doc comment for why this
    /// matters and why it's a state-revert, not a fresh `snooze()` call.
    @discardableResult
    public func markCaughtUp(contactId: UUID) async -> Bool {
        loadGeneration += 1
        groups = groups.map { header, rows in
            (header, rows.filter { !($0.contactId == contactId && $0.kind == .cadence) })
        }.filter { !$0.rows.isEmpty }
        totalCount = groups.reduce(0) { $0 + $1.rows.count }
        let logging = InteractionLogging(contacts: contacts, interactions: interactions)
        var clearedPendingSnooze = false
        do {
            clearedPendingSnooze = try await scheduler.caughtUp(contactId: contactId)
            try await logging.markCaughtUp(contactId: contactId, at: clock())
            await performLoad()
            return true
        } catch {
            Self.log.error(
                "failed to mark caught up for \(contactId, privacy: .private): \(error, privacy: .private)"
            )
            if clearedPendingSnooze {
                await restorePendingSnooze(contactId: contactId)
            }
            await performLoad()
            return false
        }
    }

    private func restorePendingSnooze(contactId: UUID) async {
        do {
            try await scheduler.restorePendingAfterFailedCaughtUp(contactId: contactId)
        } catch {
            Self.log.error(
                "failed to restore snooze for \(contactId, privacy: .private): \(error, privacy: .private)"
            )
        }
    }

    // MARK: - Row building

    private func buildRows(
        contacts: [Contact],
        reminders: [ScheduledReminder],
        now: Date
    ) -> [UpcomingRowState] {
        let calendar = Self.gregorianCalendar(for: window.timeZone)
        // Falling back to `now` would collapse the horizon to zero width and
        // silently empty the screen — the worst failure shape, because it is
        // indistinguishable from "nothing is coming up". Degrade to elapsed
        // time instead: a superset that may include an extra row across a DST
        // boundary, which is visible and harmless, rather than a subset that
        // hides real reminders.
        let horizonEnd = calendar.date(byAdding: .day, value: horizonDays, to: now)
            ?? now.addingTimeInterval(TimeInterval(horizonDays) * 86_400)
        var rows: [UpcomingRowState] = []

        // A contact's pending cadence reminder's `scheduledFor`, keyed by
        // contact id — Snooze's only persisted trace (§14 PR22's
        // `SchedulingPass.snooze` stub; no separate "snoozed" flag exists on
        // `Contact`). Inlined rather than a shared `PendingSnoozeLookup`
        // helper (staged review round 7: two call sites, below §17's
        // abstraction floor of three) — `OverdueViewModel.performLoad` has
        // its own identical copy. Once a snooze lapses this map is simply
        // not consulted and the ordinary computation below decides the date
        // unchanged, so the row "returns" on its own the next load after the
        // snoozed date passes.
        let snoozedUntilByContact = Dictionary(
            reminders
                .filter { $0.kind == .cadence }
                .map { ($0.contactId, $0.scheduledFor) },
            // `max($0, $1)`, not "whichever comes last in the array": two
            // pending cadence rows for one contact shouldn't happen (the
            // deterministic `cadenceReminderID` write-path is meant to keep
            // it to one), but if it ever did, picking by array order would
            // make the winner depend on fetch ordering rather than on which
            // row is actually later — `max` is correct regardless of order.
            uniquingKeysWith: { max($0, $1) }
        )

        func appendCadenceRow(contact: Contact, cadence: Int, fires: Date) {
            guard fires < horizonEnd else { return }
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

        for contact in contacts {
            if let cadence = contact.cadenceDays {
                let last = contact.lastInteractedAt ?? contact.createdAt
                let overdueAt = last.addingTimeInterval(TimeInterval(cadence) * 86_400)
                // A pending snooze folds into the same `target`/
                // `includingContainingSlot` computation as the ordinary
                // cadence math, rather than bypassing `nextAllowedSlot`
                // outright: an earlier version used the persisted
                // `scheduledFor` verbatim as the row's date, which could
                // land outside the window (quiet hours, a disallowed day) —
                // exactly what `nextAllowedSlot` exists to prevent. Folding
                // the snoozed instant in as a third candidate alongside `now`
                // and `overdueAt`, both here and in `includingContainingSlot`,
                // also makes a *later* caught-up beat a *stale* snooze for
                // free: caught-up moves `overdueAt` forward (via
                // `lastInteractedAt`), and `max` picks whichever of the two
                // is later without either branch needing to know about the
                // other.
                let snoozedUntil = snoozedUntilByContact[contact.id] ?? .distantPast
                let target = max(now, overdueAt, snoozedUntil)
                // `nextAllowedSlot` returns nil for a zero-capacity window
                // (R4). This is a live path, not a defensive one: the window is
                // now caller-supplied (R9a), and
                // `UpcomingViewModelStateTests.zeroCapacityWindowKeepsOccasions`
                // drives exactly this branch. Skipping the cadence row while
                // leaving occasion rows intact is the correct degradation —
                // do not delete this guard as unreachable.
                guard let fires = engine.nextAllowedSlot(
                    from: target,
                    in: window,
                    includingContainingSlot: max(overdueAt, snoozedUntil) <= now
                ) else { continue }
                // An already-overdue contact inside an active window resolves
                // to that window's slot start for deterministic batching. The
                // slot start can be earlier than `now`; it still represents an
                // immediate reminder and belongs in Upcoming. Future cadence
                // eligibility remains guarded by `nextAllowedSlot` itself.
                appendCadenceRow(contact: contact, cadence: cadence, fires: fires)
            }
        }

        // Occasion rows are seeded in the Phase 0 mock repository so their
        // birthday/anniversary states remain reachable and auditable. TF-07
        // replaces this bounded fetch with the persisted ValueObservation
        // pipeline that owns every Upcoming row (§14 PR25 / R10).
        //
        // Known deviation: §9 contract 6 (an occasion suppresses a same-day
        // cadence reminder for the same contact) is NOT enforced here. This
        // view model computes cadence rows independently of the persisted
        // reminders it reads, so it can't decide which of two candidates
        // survives without duplicating the scheduler — that's SchedulingPass's
        // job (§14 PR25 / TF-07, R6). Until it lands, a contact whose cadence
        // falls on the same local day as an occasion can appear twice; the
        // rows carry distinct IDs (R36), so the duplicate is visible rather
        // than corrupting identity or ordering.
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
}
