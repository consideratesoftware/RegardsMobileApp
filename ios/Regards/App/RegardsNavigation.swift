import Foundation
import Observation
import SwiftUI

enum RegardsTab: String, CaseIterable, Hashable, Sendable {
    case overdue
    case upcoming
    case contacts
    case settings
}

/// Owns top-level selection and one independent navigation path per tab.
/// System requests return the requested tab to its root without disturbing
/// any other tab's preserved stack.
@Observable @MainActor
final class RegardsNavigationState {
    var selected: RegardsTab
    var overduePath = NavigationPath()
    var upcomingPath = NavigationPath()
    var contactsPath = NavigationPath()
    var settingsPath = NavigationPath()
    var contactsSearchText = ""

    init(selected: RegardsTab = .overdue) {
        self.selected = selected
    }

    func openRoot(_ tab: RegardsTab) {
        switch tab {
        case .overdue:
            overduePath = NavigationPath()
        case .upcoming:
            upcomingPath = NavigationPath()
        case .contacts:
            contactsPath = NavigationPath()
            contactsSearchText = ""
        case .settings:
            settingsPath = NavigationPath()
        }
        selected = tab
    }
}

/// One explicit handoff point for system experiences that need to open the
/// app on a top-level destination. App Intents submit a request; the tab root
/// consumes it. No feature owns a hidden global routing side effect.
@Observable @MainActor
final class RegardsIntentRouter {
    struct Request: Equatable, Sendable {
        let id: UUID
        let tab: RegardsTab
    }

    static let shared = RegardsIntentRouter()

    private(set) var request: Request?
#if DEBUG
    /// Test-only observation of the most recent submission. The app never
    /// consults this value; `request` remains the sole routing source of truth.
    private(set) var lastSubmittedRequest: Request?
#endif

    init() {}

    func submit(_ tab: RegardsTab) {
        let newRequest = Request(id: UUID(), tab: tab)
        request = newRequest
#if DEBUG
        lastSubmittedRequest = newRequest
#endif
    }

    func consume(_ id: UUID) {
        guard request?.id == id else { return }
        request = nil
    }
}
