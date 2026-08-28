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

        let settled = await waitUntil { recorder.isComplete }
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
    /// its first yield invalidates the first's still-pending focus move and
    /// announcement — only the later call's effects land. Order matters
    /// here: `fire` moves focus *before* announcing (see its doc comment for
    /// why — a focus change flushes VoiceOver's speech queue, so announcing
    /// first would let the later focus move cut the announcement off), so
    /// the winning call's `focus`/`didFocus` land on the *second* resume,
    /// not the third, and its `announce` lands on the third.
    @Test("Two fire calls in quick succession: only the later one's focus and announce land")
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
        #expect(await waitUntil { suspension.arrivalCount == 1 })

        announcer.fire("Snoozed Han Solo 1 week", effects: effects) {
            recorder.focusCalls += 1
        }
        #expect(await waitUntil { suspension.arrivalCount == 2 })

        // Resume the first (stale) call's first yield: its generation check
        // now fails, so it returns without ever calling `focus()` or
        // `announce`.
        suspension.resumeNext()
        await Task.yield()
        #expect(recorder.focusCalls == 0)
        #expect(recorder.focusAssignments == 0)
        #expect(recorder.announcements.isEmpty)

        // Resume the second (current) call's first yield: its generation
        // still matches, so focus lands now, then it yields again before
        // announcing.
        suspension.resumeNext()
        #expect(await waitUntil { suspension.arrivalCount == 3 })
        #expect(recorder.focusCalls == 1)
        #expect(recorder.focusAssignments == 1)
        #expect(recorder.announcements.isEmpty)

        // Resume its second yield: the announcement lands last, with
        // nothing after it in the sequence to flush it.
        suspension.resumeNext()
        #expect(await waitUntil { recorder.announcements == ["Snoozed Han Solo 1 week"] })
        #expect(recorder.focusCalls == 1)
        #expect(recorder.focusAssignments == 1)
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
            scheduler: SchedulingPass(
                reminders: reminders,
                contacts: contacts,
                clock: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        await viewModel.load()
        #expect(viewModel.rows.count == 1)

        let announcer = RowActionAnnouncer()
        let screen = OverdueScreen(
            viewModel: viewModel,
            accessibilityEffects: .live,
            rowActionAnnouncer: announcer
        )
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
            effects: RowActionAccessibilityEffects(announce: { recorder.announcements.append($0) }, didFocus: {})
        ) {}
        let settled = await waitUntil { recorder.announcements.count == 1 }
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
                contacts: contacts,
                clock: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            interactions: StubInteractionRepository(),
            window: .allDayEveryDay(timezone: UpcomingFixtures.utc),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        await viewModel.load()
        #expect(viewModel.totalCount == 1)

        let announcer = RowActionAnnouncer()
        let screen = UpcomingScreen(
            viewModel: viewModel,
            accessibilityEffects: .live,
            rowActionAnnouncer: announcer
        )
        let host = UIHostingController(rootView: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()

        let recorder = RowActionEffectsRecorder()
        announcer.fire(
            "Marked Leia Organa caught up",
            effects: RowActionAccessibilityEffects(announce: { recorder.announcements.append($0) }, didFocus: {})
        ) {}
        let settled = await waitUntil { recorder.announcements.count == 1 }
        #expect(settled)
        window.isHidden = true
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
