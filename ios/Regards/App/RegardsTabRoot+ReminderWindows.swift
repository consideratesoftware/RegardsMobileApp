import Foundation

extension RegardsTabRoot {
    /// The global reminder-window editor, composed like the factories in
    /// `RegardsApp.swift` (same justification: `AppRuntimeTests` reaches the
    /// composition through this seam). It lives in its own file because
    /// `RegardsApp.swift` is near SwiftLint's 500-line limit.
    ///
    /// `onSaved` is how a global save reaches the live Upcoming view model
    /// (so Upcoming's horizon and rows follow a saved window); without it the
    /// tab keeps the launch window until relaunch. The
    /// editor writes through the repositories, never `runtime.window`, which
    /// stays the launch snapshot (R55 ruling: the editor cannot change a
    /// timezone, so the scheduler calendar cannot go stale).
    @MainActor
    static func makeReminderWindowsViewModel(
        runtime: AppRuntime,
        upcoming: UpcomingViewModel
    ) -> ReminderWindowsViewModel {
        ReminderWindowsViewModel(
            target: .global,
            window: runtime.environment.window,
            contacts: runtime.environment.contacts,
            clock: runtime.clock,
            onSaved: { await upcoming.updateWindow($0) }
        )
    }

    /// One contact's override editor, built per push from Contact Detail. It
    /// saves through `updateReminderWindowOverride`, so it needs no `onSaved`:
    /// Upcoming follows `observeTracked`, and Contact Detail re-reads the
    /// contact when it reappears.
    @MainActor
    static func makeContactWindowEditor(
        contactId: UUID,
        runtime: AppRuntime
    ) -> ReminderWindowsViewModel {
        ReminderWindowsViewModel(
            target: .contact(contactId),
            window: runtime.environment.window,
            contacts: runtime.environment.contacts,
            clock: runtime.clock,
            onSaved: { _ in } // An override save reaches Upcoming through observeTracked.
        )
    }
}
