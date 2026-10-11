import Foundation
import Observation

/// Live editor state for the global reminder window and a single contact's
/// override (ARCHITECTURE.md §9, §10 screen 9).
///
/// **Invariant I1.** Every window this type writes passes `validate()`, has no
/// overlapping allowed ranges, has a quiet-hours start that differs from its
/// end, and yields a non-nil `ReminderEngine.nextAllowedSlot`. All four are
/// checked in `save()` and nowhere else: `validate()` also runs when stored
/// data decodes, so a stricter rule there would make already-stored windows
/// fail at launch. A failed check writes nothing and sets `validationMessage`.
///
/// **Invariant I3.** An override copies the global timezone, occasion time, and
/// horizon at save time, and this editor never changes a timezone. R55's
/// ruling depends on that: the scheduler calendar built from the launch window
/// cannot go stale because of an edit made here.
@MainActor @Observable
public final class ReminderWindowsViewModel {

    public enum Target: Equatable, Sendable {
        case global
        case contact(UUID)
    }

    /// The fields the editor changes. Timezone is deliberately absent.
    public struct Draft: Equatable, Sendable {
        public var allowedDays: DayOfWeekMask
        public var allowedTimeRanges: [TimeRange]
        public var quietHours: TimeRange?
        public var occasionTime: TimeOfDay
        public var digestHorizonDays: Int

        public init(allowedDays: DayOfWeekMask,
                    allowedTimeRanges: [TimeRange],
                    quietHours: TimeRange?,
                    occasionTime: TimeOfDay,
                    digestHorizonDays: Int) {
            self.allowedDays = allowedDays
            self.allowedTimeRanges = allowedTimeRanges
            self.quietHours = quietHours
            self.occasionTime = occasionTime
            self.digestHorizonDays = digestHorizonDays
        }

        init(_ window: ReminderWindow) {
            self.init(allowedDays: window.allowedDays,
                      allowedTimeRanges: window.allowedTimeRanges,
                      quietHours: window.quietHours,
                      occasionTime: window.occasionTime,
                      digestHorizonDays: window.digestHorizonDays)
        }
    }

    public static let horizonChoices = [7, 14, 30]
    static let newRange = TimeRange(start: TimeOfDay(hour: 9), end: TimeOfDay(hour: 10))
    static let defaultQuietHours = TimeRange(start: TimeOfDay(hour: 22, minute: 30),
                                             end: TimeOfDay(hour: 7, minute: 30))

    public let target: Target

    /// Edits land here and nowhere else until `save()` succeeds. Changing the
    /// draft clears a stale inline message.
    public var draft: Draft {
        didSet {
            if draft != oldValue { validationMessage = nil }
        }
    }

    /// The one inline message slot: validation refusals and save failures.
    /// `nil` after a save means the repository changed.
    public private(set) var validationMessage: String?
    /// Counts refusals so the screen can announce a repeat of the same message.
    public private(set) var failureCount = 0
    public private(set) var isSaving = false
    public private(set) var timezoneIdentifier = TimeZone.current.identifier
    /// Set when the target is a contact: used for the screen header.
    public private(set) var contactName: String?
    /// True while the contact has a stored override that "Use my default
    /// window" can clear.
    public private(set) var hasStoredOverride = false
    private(set) var loadState: RegardsLoadState = .loading
    private(set) var loadFailureMessage = "Couldn't load your reminder window."

    private let window: any ReminderWindowRepository
    private let contacts: any ContactRepository
    private let clock: () -> Date
    private let onSaved: @MainActor (ReminderWindow) async -> Void
    @ObservationIgnored private var rememberedQuietHours = ReminderWindowsViewModel.defaultQuietHours

    /// `onSaved` is deliberately undefaulted: it is how a global save reaches
    /// `UpcomingViewModel.updateWindow` (I2). A defaulted no-op is how an
    /// editor ends up saving a window the Upcoming tab never sees. It is not
    /// called for an override save, which reaches Upcoming through
    /// `observeTracked`.
    public init(target: Target,
                window: any ReminderWindowRepository,
                contacts: any ContactRepository,
                clock: @escaping () -> Date = { Date() },
                onSaved: @escaping @MainActor (ReminderWindow) async -> Void) {
        self.target = target
        self.window = window
        self.contacts = contacts
        self.clock = clock
        self.onSaved = onSaved
        let seed = ReminderWindow.defaultV1()
        self.draft = Draft(seed)
    }

    // MARK: - Load

    public func load() async {
        loadState = .loading
        do {
            let global = try await window.fetchGlobal()
            timezoneIdentifier = global.timezoneIdentifier
            switch target {
            case .global:
                draft = Draft(global)
            case .contact(let id):
                guard let contact = try await contacts.fetch(id: id), contact.archivedAt == nil else {
                    loadFailureMessage = "This contact is no longer available."
                    loadState = .failed
                    return
                }
                contactName = contact.displayName
                hasStoredOverride = contact.reminderWindowOverride != nil
                draft = Draft(contact.reminderWindowOverride ?? global)
            }
            if let quiet = draft.quietHours { rememberedQuietHours = quiet }
            validationMessage = nil
            loadState = .loaded
        } catch {
            loadFailureMessage = "Couldn't load your reminder window."
            loadState = .failed
        }
    }

    // MARK: - Editing

    public func isDayAllowed(_ day: DayOfWeekMask) -> Bool {
        draft.allowedDays.contains(day)
    }

    public func toggleDay(_ day: DayOfWeekMask) {
        draft.allowedDays.formSymmetricDifference(day)
    }

    /// Adds 09:00 to 10:00. If that overlaps an existing range, `save()`
    /// refuses and says so.
    public func addRange() {
        draft.allowedTimeRanges.append(Self.newRange)
    }

    public var canRemoveRange: Bool { draft.allowedTimeRanges.count > 1 }

    public func removeRange(at index: Int) {
        guard canRemoveRange, draft.allowedTimeRanges.indices.contains(index) else { return }
        draft.allowedTimeRanges.remove(at: index)
    }

    public func setRange(at index: Int, start: TimeOfDay? = nil, end: TimeOfDay? = nil) {
        guard draft.allowedTimeRanges.indices.contains(index) else { return }
        let old = draft.allowedTimeRanges[index]
        draft.allowedTimeRanges[index] = TimeRange(start: start ?? old.start, end: end ?? old.end)
    }

    public var quietHoursEnabled: Bool {
        get { draft.quietHours != nil }
        set {
            if newValue {
                draft.quietHours = draft.quietHours ?? rememberedQuietHours
            } else {
                if let quiet = draft.quietHours { rememberedQuietHours = quiet }
                draft.quietHours = nil
            }
        }
    }

    public func setQuietHours(start: TimeOfDay? = nil, end: TimeOfDay? = nil) {
        let old = draft.quietHours ?? rememberedQuietHours
        let updated = TimeRange(start: start ?? old.start, end: end ?? old.end)
        draft.quietHours = updated
        rememberedQuietHours = updated
    }

    // MARK: - Save

    /// Checks I1 once, then writes. Returns whether the write landed.
    @discardableResult
    public func save() async -> Bool {
        guard loadState == .loaded, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let global = try await window.fetchGlobal()
            let candidate = makeWindow(global: global)
            if let refusal = refusal(for: candidate) {
                fail(refusal)
                return false
            }
            switch target {
            case .global:
                try await window.saveGlobal(candidate)
                await onSaved(candidate)
            case .contact(let id):
                guard try await contacts.updateReminderWindowOverride(id: id, window: candidate) else {
                    fail("This contact is no longer available, so the window wasn't saved.")
                    return false
                }
                hasStoredOverride = true
            }
            validationMessage = nil
            return true
        } catch {
            fail("Couldn't save your reminder window. Try again.")
            return false
        }
    }

    /// Clears the contact's override so they follow the global window again.
    @discardableResult
    public func resetToDefault() async -> Bool {
        guard case .contact(let id) = target, loadState == .loaded, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            guard try await contacts.updateReminderWindowOverride(id: id, window: nil) else {
                fail("This contact is no longer available.")
                return false
            }
            hasStoredOverride = false
            validationMessage = nil
            return true
        } catch {
            fail("Couldn't switch back to your default window. Try again.")
            return false
        }
    }

    // MARK: - Validation

    /// The global window supplies the timezone for both targets, and the
    /// occasion time and horizon for an override (I3).
    private func makeWindow(global: ReminderWindow) -> ReminderWindow {
        switch target {
        case .global:
            return ReminderWindow(
                allowedDays: draft.allowedDays,
                allowedTimeRanges: draft.allowedTimeRanges,
                quietHours: draft.quietHours,
                timezoneIdentifier: global.timezoneIdentifier,
                occasionTime: draft.occasionTime,
                digestHorizonDays: draft.digestHorizonDays
            )
        case .contact:
            return ReminderWindow(
                allowedDays: draft.allowedDays,
                allowedTimeRanges: draft.allowedTimeRanges,
                quietHours: draft.quietHours,
                timezoneIdentifier: global.timezoneIdentifier,
                occasionTime: global.occasionTime,
                digestHorizonDays: global.digestHorizonDays
            )
        }
    }

    private func refusal(for candidate: ReminderWindow) -> String? {
        do {
            try candidate.validate()
        } catch let error as ReminderWindow.ValidationError {
            return Self.message(for: error)
        } catch {
            return "This window isn't valid."
        }
        if Self.hasOverlap(candidate.allowedTimeRanges) {
            return "Time ranges can't overlap. Move one so it starts after the other ends."
        }
        if let quiet = candidate.quietHours, quiet.start == quiet.end {
            return "Quiet hours need a start and an end that differ."
        }
        if ReminderEngine().nextAllowedSlot(from: clock(), in: candidate) == nil {
            return "Quiet hours cover every allowed time, so no reminder could ever fire. "
                + "Shorten the quiet hours or add a time range."
        }
        return nil
    }

    private static func message(for error: ReminderWindow.ValidationError) -> String {
        switch error {
        case .noAllowedDays:
            return "Pick at least one day."
        case .noAllowedTimeRanges:
            return "Add at least one time range."
        case .zeroLengthRange:
            return "A time range can't start and end at the same time."
        case .wrappingAllowedRange:
            return "A time range has to end later the same day. "
                + "Only quiet hours can run past midnight."
        case .invalidTimezoneIdentifier, .invalidDigestHorizonDays:
            return "This window isn't valid."
        }
    }

    /// Touching ranges (one ends where the next starts) are fine.
    private static func hasOverlap(_ ranges: [TimeRange]) -> Bool {
        let sorted = ranges.sorted { $0.start < $1.start }
        return zip(sorted, sorted.dropFirst()).contains { $1.start < $0.end }
    }

    private func fail(_ message: String) {
        validationMessage = message
        failureCount += 1
    }
}
