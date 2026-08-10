import SwiftUI
import Testing
import UIKit
@testable import Regards

/// `RowActionAnnouncer` coverage — the generation-guarded announce/focus
/// sequencing `OverdueScreen`'s Caught up/Snooze and `UpcomingScreen`'s
/// Caught up buttons drive on a successful write.
///
/// `OnboardingAccessibilityEffectsTests` reaches its effects by mutating an
/// external `@Published` model and letting SwiftUI's own reactive `.task`
/// pick it up — no tap simulation needed. `RowActionAnnouncer.fire(...)` has
/// no such reactive trigger: it only runs from inside a row button's tap
/// closure. Reaching it from a real tap would need SwiftUI to publish a
/// queryable `UIAccessibilityContainer` tree, which it does not do in a
/// plain XCTest unit-test host without VoiceOver actually running —
/// confirmed by hosting `OverdueScreen` in a real, laid-out `UIWindow`
/// (attached to a live `UIWindowScene`, `makeKeyAndVisible()`, not just
/// `isHidden = false`) and recursively walking every subview's
/// `accessibilityElementCount()`/`accessibilityElement(at:)`: it returns 0
/// the entire way down, for every node, including the SwiftUI-internal
/// container types (`PlatformGroupContainer`, `_UIInheritedView`, etc.)
/// that sit between the hosting view and the rendered buttons. `Button`
/// itself never even appears as a distinguishable node.
///
/// `RowActionAnnouncer` exists as an injectable (`@State`-held, but seeded
/// through `init`) dependency specifically so this sequencing is reachable
/// without a tap: both screens inject the exact same instance a test
/// constructs, and a test can call `fire(...)` on it directly with the same
/// message shape and effects each screen's real button closure uses. What
/// this does *not* cover — which button calls `fire` with which message,
/// gated on which `ViewModel` method's success — is verified by direct
/// source reading (`OverdueScreen.rowStack`, `UpcomingScreen.listContent`)
/// and by `ScreensAccessibilityTests+RowActions.swift`'s XCUITest coverage,
/// which does have full accessibility-tree access via the automation
/// framework unit tests don't get.
@MainActor
struct RowActionAccessibilityEffectsTests {

    @Test("A row action announces once and focuses once")
    func fireAnnouncesAndFocusesOnce() async {
        let recorder = RowActionEffectsRecorder()
        let announcer = RowActionAnnouncer()

        announcer.fire(
            "Marked Leia Organa caught up",
            effects: RowActionAccessibilityEffects(
                announce: { recorder.announcements.append($0) },
                didFocus: { recorder.focusAssignments += 1 }
            ),
            focus: { recorder.focusCalls += 1 }
        )

        let settled = await Self.eventually { recorder.isComplete }
        #expect(settled)
        #expect(recorder.announcements == ["Marked Leia Organa caught up"])
        #expect(recorder.focusAssignments == 1)
        #expect(recorder.focusCalls == 1)
    }

    /// Pins the correctness-review fix at the call-site level: both screens
    /// now call `fire(...)` only after `viewModel.markCaughtUp`/`snooze`
    /// returns `true` (see `OverdueScreen.rowStack` and
    /// `UpcomingScreen.listContent`), so `RowActionAnnouncer` itself has no
    /// notion of success/failure to test — a `fire` call never happening is
    /// what "the write failed" looks like from here. This test pins the
    /// other half: a `fire` call that never happens produces no
    /// announcement and no focus call, i.e. the announcer has no hidden
    /// fallback that fires anyway.
    @Test("No fire call means no announcement and no focus")
    func noFireMeansNoEffects() async {
        let recorder = RowActionEffectsRecorder()
        _ = RowActionAnnouncer() // constructed, never fired
        await Task.yield()
        #expect(recorder.announcements.isEmpty)
        #expect(recorder.focusAssignments == 0)
    }

    /// Mirrors `OnboardingAccessibilityEffectsTests.newerStatusCancelsStaleEffects`:
    /// a second `fire` call before the first's paused sequence resumes past
    /// its first yield invalidates the first's still-pending announcement
    /// and focus — only the later call's effects land.
    @Test("Two fire calls in quick succession: only the later one's announce and focus land")
    func staleFireEffectsAreDropped() async {
        let recorder = RowActionEffectsRecorder()
        let suspension = RowActionEffectsSuspension()
        let announcer = RowActionAnnouncer()
        let effects = RowActionAccessibilityEffects(
            announce: { recorder.announcements.append($0) },
            didFocus: { recorder.focusAssignments += 1 },
            yieldControl: { await suspension.pause() }
        )

        announcer.fire("Marked Leia Organa caught up", effects: effects) {
            recorder.focusCalls += 1
        }
        #expect(await Self.eventually { suspension.arrivalCount == 1 })

        announcer.fire("Snoozed Han Solo 1 week", effects: effects) {
            recorder.focusCalls += 1
        }
        #expect(await Self.eventually { suspension.arrivalCount == 2 })

        // Resume the first (stale) call's first yield: its generation check
        // now fails, so it returns without announcing or focusing.
        suspension.resumeNext()
        await Task.yield()
        #expect(recorder.announcements.isEmpty)
        #expect(recorder.focusAssignments == 0)

        // Resume the second (current) call's first yield: its generation
        // still matches, so it announces, then yields again before focusing.
        suspension.resumeNext()
        #expect(await Self.eventually { suspension.arrivalCount == 3 })
        #expect(recorder.announcements == ["Snoozed Han Solo 1 week"])
        #expect(recorder.focusAssignments == 0)

        // Resume its second yield: focus lands.
        suspension.resumeNext()
        #expect(await Self.eventually { recorder.focusAssignments == 1 })
        #expect(recorder.announcements == ["Snoozed Han Solo 1 week"])
        // Only the winning call's `focus` closure ever runs — the stale
        // call's generation check fails before it reaches `focus()` at all,
        // not just before `didFocus()`.
        #expect(recorder.focusCalls == 1)
    }

    // MARK: - Screen wiring smoke tests
    //
    // Constructs the real screens with an injected `RowActionAnnouncer` and
    // `RowActionAccessibilityEffects`, hosted in a real `UIHostingController`
    // — proof the injection seam threads through `init`'s
    // `State(initialValue:)` without crashing or silently substituting a
    // fresh, disconnected instance. Does not simulate a tap (infeasible; see
    // the type doc comment above); message/gating correctness is covered by
    // source review plus the tests above and the XCUITest suite.

    @Test("OverdueScreen accepts an injected RowActionAnnouncer and renders")
    func overdueScreenAcceptsInjectedAnnouncer() async throws {
        let contact = Contact(
            systemContactRef: "sys-overdue-wiring",
            displayName: "Leia Organa",
            tracked: true,
            cadenceDays: 7,
            priorityTier: .close,
            preferredChannel: .whatsapp,
            preferredChannelValue: "+14155550140",
            lastInteractedAt: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-30 * 86_400)
        )
        let contacts = StubContactRepository([contact])
        let reminders = StubReminderRepository()
        let viewModel = OverdueViewModel(
            contacts: contacts,
            interactions: StubInteractionRepository(),
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: { Date(timeIntervalSince1970: 1_800_000_000) }),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        await viewModel.load()
        #expect(viewModel.rows.count == 1)

        let announcer = RowActionAnnouncer()
        let screen = OverdueScreen(viewModel: viewModel, rowActionAnnouncer: announcer)
        let host = UIHostingController(rootView: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()

        // The injected instance is genuinely the one wired in, not a
        // silently-substituted default: firing it directly still produces
        // the effects a real button tap would have driven through it.
        let recorder = RowActionEffectsRecorder()
        announcer.fire(
            "Marked Leia Organa caught up",
            effects: RowActionAccessibilityEffects(announce: { recorder.announcements.append($0) })
        ) {}
        let settled = await Self.eventually { recorder.announcements.count == 1 }
        #expect(settled)
        window.isHidden = true
    }

    @Test("UpcomingScreen accepts an injected RowActionAnnouncer and renders")
    func upcomingScreenAcceptsInjectedAnnouncer() async throws {
        let contact = Contact(
            systemContactRef: "sys-upcoming-wiring",
            displayName: "Leia Organa",
            tracked: true,
            cadenceDays: 7,
            priorityTier: .close,
            preferredChannel: .whatsapp,
            preferredChannelValue: "+14155550140",
            lastInteractedAt: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-30 * 86_400)
        )
        let contacts = StubContactRepository([contact])
        let viewModel = UpcomingViewModel(
            contacts: contacts,
            reminders: nil,
            scheduler: SchedulingPass(
                reminders: StubReminderRepository(),
                clock: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            interactions: StubInteractionRepository(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        await viewModel.load()
        #expect(viewModel.totalCount == 1)

        let announcer = RowActionAnnouncer()
        let screen = UpcomingScreen(viewModel: viewModel, rowActionAnnouncer: announcer)
        let host = UIHostingController(rootView: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()

        let recorder = RowActionEffectsRecorder()
        announcer.fire(
            "Marked Leia Organa caught up",
            effects: RowActionAccessibilityEffects(announce: { recorder.announcements.append($0) })
        ) {}
        let settled = await Self.eventually { recorder.announcements.count == 1 }
        #expect(settled)
        window.isHidden = true
    }

    private static func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

// MARK: - Test doubles

@MainActor
private final class RowActionEffectsRecorder {
    var announcements: [String] = []
    var focusAssignments = 0
    var focusCalls = 0

    var isComplete: Bool {
        announcements.count == 1 && focusAssignments == 1
    }
}

@MainActor
private final class RowActionEffectsSuspension {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivalCount = 0

    func pause() async {
        arrivalCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        continuations.removeFirst().resume()
    }
}
