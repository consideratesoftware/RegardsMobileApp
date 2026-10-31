import Foundation

extension RegardsTabRoot {
    /// The Settings starter picker ("Choose people to keep in touch with"),
    /// composed like the factories in `RegardsApp.swift` so `AppRuntimeTests`
    /// can reach it. It lives in its own file because `RegardsApp.swift` is
    /// near SwiftLint's 500-line limit.
    ///
    /// `onSaved` reschedules each contact whose tracking write landed through
    /// the runtime's one `SchedulingPass` (§9: starter tracking is a cadence
    /// edit). A failed run is logged, not shown: the picker has no banner,
    /// and the next foreground `runFull()` repairs it.
    @MainActor
    static func makeStarterContactsViewModel(runtime: AppRuntime) -> StarterContactsViewModel {
        StarterContactsViewModel(
            contacts: runtime.environment.contacts,
            onSaved: { contactIds in
                for contactId in contactIds {
                    do {
                        try await runtime.scheduler.run(for: contactId)
                    } catch {
                        // The type only: an error can carry row or contact values.
                        let errorType = String(describing: type(of: error))
                        starterSchedulingLog.error(
                            "reschedule after starter save failed: \(errorType, privacy: .public)"
                        )
                    }
                }
            }
        )
    }

    private static let starterSchedulingLog = RegardsLogger.feature("SchedulingPass")
}
