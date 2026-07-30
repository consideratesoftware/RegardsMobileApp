import Foundation
import Testing
@testable import Regards

@MainActor
struct RegardsIntentRouterTests {
    @Test("Repeated requests for the same tab retain distinct identities")
    func repeatedRequestsStayObservable() throws {
        let router = RegardsIntentRouter()

        router.submit(.contacts)
        let first = try #require(router.request)

        router.submit(.contacts)
        let second = try #require(router.request)

        #expect(first.tab == .contacts)
        #expect(second.tab == .contacts)
        #expect(first.id != second.id)
        router.consume(second.id)
    }

    @Test("Only the current request can be consumed")
    func consumeUsesRequestIdentity() throws {
        let router = RegardsIntentRouter()

        router.submit(.upcoming)
        let request = try #require(router.request)

        router.consume(UUID())
        #expect(router.request == request)

        router.consume(request.id)
        #expect(router.request == nil)
    }

    @available(iOS 26.0, *)
    @Test("The App Intent routes every public section without personal data")
    func appIntentRoutesPublicSections() async throws {
        #expect(OpenRegardsSectionIntent.supportedModes == .foreground(.immediate))
        #expect(RegardsTab.allCases == [.overdue, .upcoming, .contacts, .settings])

        for tab in RegardsTab.allCases {
            let intent = OpenRegardsSectionIntent()
            intent.section = tab

            _ = try await intent.perform()
            let submitted = try #require(
                RegardsIntentRouter.shared.lastSubmittedRequest
            )
            #expect(submitted.tab == tab)
            if let pending = RegardsIntentRouter.shared.request {
                RegardsIntentRouter.shared.consume(pending.id)
            }
        }

        #expect(RegardsIntentRouter.shared.request == nil)
    }

    @Test("Opening a section resets only that tab to its root")
    func openSectionResetsRequestedPath() {
        let navigation = RegardsNavigationState(selected: .contacts)
        navigation.overduePath.append(UUID())
        navigation.contactsPath.append(UUID())

        navigation.openRoot(.contacts)

        #expect(navigation.selected == .contacts)
        #expect(navigation.contactsPath.isEmpty)
        #expect(navigation.overduePath.count == 1)
    }

    @Test("Repeated same-tab requests still return to the section root")
    func repeatedSameTabRequestReturnsToRoot() {
        let navigation = RegardsNavigationState(selected: .settings)

        navigation.settingsPath.append(RegardsSettingsRoute.transparency)
        navigation.openRoot(.settings)
        #expect(navigation.settingsPath.isEmpty)

        navigation.settingsPath.append(RegardsSettingsRoute.reminderWindows)
        navigation.openRoot(.settings)
        #expect(navigation.selected == .settings)
        #expect(navigation.settingsPath.isEmpty)
    }
}
