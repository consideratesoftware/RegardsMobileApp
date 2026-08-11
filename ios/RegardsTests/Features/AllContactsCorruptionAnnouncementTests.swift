import Foundation
import SwiftUI
import Testing
@testable import Regards

/// Should-fix 9: when `corruptionMessage` newly becomes non-nil — whether on
/// first load or a later `reconciliationGeneration`-driven reload — the
/// screen must post a VoiceOver announcement, the same repo pattern
/// `RegardsApp`/`OnboardingScreen` already use for their own recoverable
/// states. This hosts the real screen (SwiftUI `.task`/`.onChange`
/// lifecycle, no UIKit accessibility-tree walking — that path is
/// CI-fragile, see the deleted `AllContactsCorruptionAccessibilityTests`)
/// and asserts through an injected effects closure instead.
///
/// Round 10: the announcement must only fire while this screen is actually
/// the visible tab. `RegardsTabRoot` mounts every tab's content inside one
/// `TabView`, so a background `CNContactStoreDidChange` reconciling while
/// the user sits on Overdue/Detail/Settings still reloads this screen's
/// data (`reconciliationGeneration` doesn't care which tab is frontmost) —
/// interrupting VoiceOver on a screen the user isn't looking at to announce
/// a banner on a different one is wrong; they reach it in reading order
/// once they do arrive. Both tests below host `AllContactsScreen` inside a
/// real 2-tab `TabView` and drive `selection` the same way a user switching
/// tabs would, rather than conditionally mounting/unmounting the screen —
/// mounted-but-backgrounded is exactly the shape `.onAppear`/`.onDisappear`
/// need to distinguish from actually-visible, and conditional mounting
/// wouldn't exercise that distinction (it would just stop `.task`/
/// `.onChange` from running at all, which isn't the real scenario).
@MainActor
struct AllContactsCorruptionAnnouncementTests {
    @Test("The corruption banner announces once when it newly appears while the tab is visible")
    func announcesOnlyOnNilToNonNilTransitionWhileVisible() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let healthy = Contact(systemContactRef: "healthy-1", displayName: "Healthy", tracked: false)
        let repository = SettableContactRepository(contacts: [healthy])
        let viewModel = AllContactsViewModel(contacts: repository, clock: { now })
        let model = ReconciliationGenerationModel()
        let selection = TabSelectionModel(selectedTab: .contacts)
        let recorder = AnnouncementRecorder()
        let visibility = VisibilityRecorder()
        let host = UIHostingController(
            rootView: AnnouncementHarness(
                viewModel: viewModel, model: model, selection: selection, recorder: recorder, visibility: visibility
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // Initial load has no corruption — no announcement. Also settle to
        // the screen's own `.onAppear` having actually landed (not just
        // `loadState`, a separate signal driven by `.task`) before treating
        // "visible" as a known starting condition below.
        #expect(await eventually { viewModel.loadState == .loaded })
        #expect(await eventuallyPumpingRunLoop { visibility.latest == true })
        #expect(recorder.announcements.isEmpty)

        // Reconciliation discovers a corrupt row: nil → "1 contact...".
        await repository.setReport(Self.report(healthy: healthy, corruptedCount: 1))
        model.reconciliationGeneration += 1

        #expect(await eventually { recorder.announcements.count == 1 })
        #expect(recorder.announcements == ["1 contact couldn't be read and needs attention."])

        // A further reload finds a *second* corrupt row: "1 contact..." →
        // "2 contacts..." is a genuine value change (SwiftUI's `.onChange`
        // does fire), but the message was already non-nil, so the
        // nil-to-non-nil guard must still suppress a second announcement.
        await repository.setReport(Self.report(healthy: healthy, corruptedCount: 2))
        model.reconciliationGeneration += 1

        #expect(await eventually { viewModel.corruptedContactCount == 2 })
        #expect(recorder.announcements.count == 1)

        window.isHidden = true
    }

    @Test("The corruption banner reloads but does not announce while a different tab is visible")
    func doesNotAnnounceWhileScreenIsNotVisible() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let healthy = Contact(systemContactRef: "healthy-1", displayName: "Healthy", tracked: false)
        let repository = SettableContactRepository(contacts: [healthy])
        let viewModel = AllContactsViewModel(contacts: repository, clock: { now })
        let model = ReconciliationGenerationModel()
        let selection = TabSelectionModel(selectedTab: .contacts)
        let recorder = AnnouncementRecorder()
        let visibility = VisibilityRecorder()
        let host = UIHostingController(
            rootView: AnnouncementHarness(
                viewModel: viewModel, model: model, selection: selection, recorder: recorder, visibility: visibility
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // Land on the Contacts tab first so it actually mounts (SwiftUI's
        // `TabView` only instantiates the selected tab's content) and its
        // initial healthy load completes.
        #expect(await eventually { viewModel.loadState == .loaded })
        #expect(await eventuallyPumpingRunLoop { visibility.latest == true })

        // Switch away — the screen stays mounted (`.task`/`.onChange` keep
        // working, proven below by the reload actually happening) but is no
        // longer the frontmost tab. `window.layoutIfNeeded()` forces a
        // layout pass, but SwiftUI dispatches `.onDisappear` on its own
        // run-loop schedule, not synchronously inside that call — a flake
        // traced to exactly this gap: reconciliation could fire (below)
        // before `.onDisappear` had actually landed, so the announcement
        // gate was still reading `isCurrentlyVisible == true` at the moment
        // it mattered. Settling on `visibility.latest == false` (via the
        // screen's own `visibilityChangeObserver`, not a fixed number of
        // yields) is the bounded, deterministic point that proves the
        // transition happened before anything below can race it.
        selection.selectedTab = .other
        window.layoutIfNeeded()
        #expect(await eventuallyPumpingRunLoop { visibility.latest == false })

        await repository.setReport(Self.report(healthy: healthy, corruptedCount: 1))
        model.reconciliationGeneration += 1

        #expect(await eventually { viewModel.corruptionMessage != nil })
        #expect(
            recorder.announcements.isEmpty,
            "a reload while a different tab is frontmost must not interrupt VoiceOver there"
        )

        window.isHidden = true
    }

    private static func report(healthy: Contact, corruptedCount: Int) -> ContactFetchReport {
        ContactFetchReport(
            contacts: [healthy],
            corrupted: (0..<corruptedCount).map { index in
                ContactCorruptionDiagnostic(
                    rawId: "bad-\(index)", systemContactRef: "bad-\(index)", reason: "decode failed"
                )
            }
        )
    }
}

@MainActor
private final class ReconciliationGenerationModel: ObservableObject {
    @Published var reconciliationGeneration = 0
}

private enum HarnessTab: Hashable {
    case contacts
    case other
}

@MainActor
private final class TabSelectionModel: ObservableObject {
    @Published var selectedTab: HarnessTab

    init(selectedTab: HarnessTab) {
        self.selectedTab = selectedTab
    }
}

/// Mirrors `RegardsTabRoot`'s shape closely enough to exercise real
/// `TabView` mount/appear semantics: `AllContactsScreen` sits alongside a
/// second, otherwise-irrelevant tab so switching `selection.selectedTab`
/// drives genuine `.onAppear`/`.onDisappear` calls without ever removing
/// the screen from the view tree.
private struct AnnouncementHarness: View {
    let viewModel: AllContactsViewModel
    @ObservedObject var model: ReconciliationGenerationModel
    @ObservedObject var selection: TabSelectionModel
    let recorder: AnnouncementRecorder
    let visibility: VisibilityRecorder

    var body: some View {
        TabView(selection: $selection.selectedTab) {
            Text("Other tab")
                .tabItem { Text("Other") }
                .tag(HarnessTab.other)
            configuredScreen
                .tabItem { Text("Contacts") }
                .tag(HarnessTab.contacts)
        }
    }

    private var configuredScreen: some View {
        var screen = AllContactsScreen(
            viewModel: viewModel,
            searchText: .constant(""),
            reconciliationGeneration: model.reconciliationGeneration
        )
        screen.corruptionAnnouncementEffects = AllContactsCorruptionAnnouncementEffects(
            announce: { message in recorder.record(message) }
        )
        screen.visibilityChangeObserver = { isVisible in visibility.record(isVisible) }
        return screen
    }
}

@MainActor
private final class AnnouncementRecorder {
    private(set) var announcements: [String] = []
    func record(_ message: String) {
        announcements.append(message)
    }
}

/// Mirrors `AnnouncementRecorder`'s shape for `AllContactsScreen`'s
/// `visibilityChangeObserver` — gives a test a deterministic, pollable
/// signal for when `.onAppear`/`.onDisappear` have actually landed, instead
/// of assuming a `window.layoutIfNeeded()` after a programmatic tab switch
/// was enough. `latest` starts `nil` (no transition observed yet) so
/// `eventuallyPumpingRunLoop { visibility.latest == false }` can't pass on a
/// stale default; it has to see the real `.onDisappear` fire.
@MainActor
private final class VisibilityRecorder {
    private(set) var latest: Bool?
    func record(_ isVisible: Bool) {
        latest = isVisible
    }
}
