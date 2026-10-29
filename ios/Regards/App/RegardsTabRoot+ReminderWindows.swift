import Foundation

extension RegardsTabRoot {
    /// The global reminder-window editor, composed like the factories in
    /// `RegardsApp.swift` (same justification: `AppRuntimeTests` reaches the
    /// composition through this seam). It lives in its own file because
    /// `RegardsApp.swift` is near SwiftLint's 500-line limit.
    ///
    /// `onSaved` reschedules every contact through the runtime's one
    /// `SchedulingPass` (§9 "Global window change"), then hands the window to
    /// the live Upcoming view model, which reads the snoozes the pass just
    /// re-resolved. The pass reads the stored window on every run (R55), so
    /// `runtime.window` can stay the launch snapshot.
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
            onSaved: { window in
                do {
                    try await runtime.scheduler.runFull()
                } catch {
                    schedulingLog.error("reschedule after window save failed: \(error, privacy: .private)")
                }
                await upcoming.updateWindow(window)
            }
        )
    }

    /// One contact's override editor, built per push from Contact Detail. A
    /// save or reset reschedules that contact (§9 "override change"); Upcoming
    /// follows through `observeTracked`, and Contact Detail re-reads the
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
            onSaved: { _ in
                do {
                    try await runtime.scheduler.run(for: contactId)
                } catch {
                    schedulingLog.error("reschedule after override save failed: \(error, privacy: .private)")
                }
            }
        )
    }

    private static let schedulingLog = RegardsLogger.feature("SchedulingPass")
}
