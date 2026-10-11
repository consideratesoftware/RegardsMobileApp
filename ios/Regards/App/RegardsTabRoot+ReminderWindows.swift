import Foundation

extension RegardsTabRoot {
    /// The global reminder-window editor, composed like the factories in
    /// `RegardsApp.swift` (same justification: `AppRuntimeTests` reaches the
    /// composition through this seam). It lives in its own file because
    /// `RegardsApp.swift` is at SwiftLint's 500-line limit.
    ///
    /// `onSaved` is how a global save reaches the live Upcoming view model
    /// (I2); without it the tab keeps the launch window until relaunch. The
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
}
