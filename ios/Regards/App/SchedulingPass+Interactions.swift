import Foundation

// In its own file only to keep SchedulingPass.swift under `file_length`.
extension SchedulingPass {
    /// What the user did, for `recordInteraction`: Caught up from a screen
    /// or from a notification, or "Log other channel…" through `channel`.
    public enum Interaction: Sendable, Equatable {
        case caughtUp
        case caughtUpFromNotification
        case other(Channel)
    }
}
