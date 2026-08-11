import XCTest

/// Wiring, labeling, and layout coverage for the §14 PR22 row controls
/// (Overdue's Caught up / Snooze, Upcoming's Caught up) and Contact Detail's
/// Log other channel picker — split from `ScreensAccessibilityTests.swift`
/// to keep that file's audit-per-screen shape focused.
extension ScreensAccessibilityTests {

    @MainActor
    func testOverdueRowActionsAreWiredAndLabeled() {
        let app = launchToOverdue()
        // `ios/docs/accessibility.md` §1: `waitForExistence` only on a plain
        // element query, never on a `.matching(identifier:)` predicate
        // query — the predicate pass can observe existence well ahead of
        // its own match, and under simulator slowness that lag can exceed
        // the timeout even though the element is already on screen.
        let plainCaughtUp = app.descendants(matching: .any)["overdue.caught-up"]
        let plainSnooze = app.descendants(matching: .any)["overdue.snooze"]
        XCTAssertTrue(plainCaughtUp.waitForExistence(timeout: 10))
        XCTAssertTrue(plainSnooze.waitForExistence(timeout: 10))

        let firstCaughtUp = app.descendants(matching: .any)
            .matching(identifier: "overdue.caught-up")
            .firstMatch
        let firstSnooze = app.descendants(matching: .any)
            .matching(identifier: "overdue.snooze")
            .firstMatch

        // Real, hittable buttons — not the muted unavailable-text shape
        // `assertUnavailableElement` checks elsewhere on this screen (the
        // channel pill).
        XCTAssertTrue(app.buttons.matching(identifier: "overdue.caught-up").firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(identifier: "overdue.snooze").firstMatch.exists)
        XCTAssertTrue(firstCaughtUp.isEnabled)
        XCTAssertTrue(firstSnooze.isEnabled)
        XCTAssertTrue(firstCaughtUp.label.hasPrefix("Mark "))
        XCTAssertTrue(firstCaughtUp.label.hasSuffix(" caught up"))
        XCTAssertTrue(firstSnooze.label.hasPrefix("Snooze "))
        XCTAssertTrue(firstSnooze.label.hasSuffix(" 1 week"))
    }

    @MainActor
    func testUpcomingRowActionIsWiredAndLabeled() {
        let app = launchToOverdue()
        navigateToTab(
            named: "Upcoming",
            from: "screen.overdue",
            to: "screen.upcoming",
            in: app
        )
        // Plain subscript first — see the matching comment in
        // `testOverdueRowActionsAreWiredAndLabeled` above.
        let plainCaughtUp = app.descendants(matching: .any)["upcoming.caught-up"]
        XCTAssertTrue(plainCaughtUp.waitForExistence(timeout: 10))

        let firstCaughtUp = app.descendants(matching: .any)
            .matching(identifier: "upcoming.caught-up")
            .firstMatch
        XCTAssertTrue(app.buttons.matching(identifier: "upcoming.caught-up").firstMatch.exists)
        XCTAssertTrue(firstCaughtUp.isEnabled)
        XCTAssertTrue(firstCaughtUp.label.hasPrefix("Mark "))
        XCTAssertTrue(firstCaughtUp.label.hasSuffix(" caught up"))
    }

    /// Accessibility FIX item, not optional (staged review): the two new row
    /// buttons must remain visually distinct at the largest Dynamic Type
    /// size, matching the stacking coverage every other repeated-layout
    /// control on this screen already has (`testAccessibility5AdaptiveContentDoesNotOverlap`
    /// in `ScreensAccessibilityTests+Contracts.swift`).
    @MainActor
    func testOverdueRowActionsDoNotOverlapAtAccessibility5() {
        let app = launchToOverdue(dynamicTypeSize: "accessibility5")
        // Plain subscript first — see the matching comment in
        // `testOverdueRowActionsAreWiredAndLabeled` above.
        let plainCaughtUp = app.descendants(matching: .any)["overdue.caught-up"]
        let plainSnooze = app.descendants(matching: .any)["overdue.snooze"]
        XCTAssertTrue(plainCaughtUp.waitForExistence(timeout: 10))
        XCTAssertTrue(plainSnooze.waitForExistence(timeout: 10))

        let firstCaughtUp = app.descendants(matching: .any)
            .matching(identifier: "overdue.caught-up")
            .firstMatch
        let firstSnooze = app.descendants(matching: .any)
            .matching(identifier: "overdue.snooze")
            .firstMatch
        assertStacked(
            firstSnooze,
            below: firstCaughtUp,
            "Snooze must stack below Caught up at accessibility5 on an Overdue row."
        )
    }

    /// Same coverage as `testOverdueRowActionsDoNotOverlapAtAccessibility5`,
    /// for Upcoming's row button and Caught up button — this screen had no
    /// intra-row overlap assertion at all despite carrying the identical
    /// two-control `AccessibilityAdaptiveLayout` shape (row button stacks
    /// above `caughtUpButton` at accessibility5 — see `UpcomingRow.body`'s
    /// `accessibility:` closure).
    @MainActor
    func testUpcomingRowActionDoesNotOverlapRowAtAccessibility5() {
        let app = launchToOverdue(dynamicTypeSize: "accessibility5")
        navigateToTab(
            named: "Upcoming",
            from: "screen.overdue",
            to: "screen.upcoming",
            in: app
        )
        // Plain subscript first — see the matching comment in
        // `testOverdueRowActionsAreWiredAndLabeled` above.
        let plainRow = app.descendants(matching: .any)["upcoming.row"]
        let plainCaughtUp = app.descendants(matching: .any)["upcoming.caught-up"]
        XCTAssertTrue(plainRow.waitForExistence(timeout: 10))
        XCTAssertTrue(plainCaughtUp.waitForExistence(timeout: 10))

        let firstRow = app.descendants(matching: .any)
            .matching(identifier: "upcoming.row")
            .firstMatch
        let firstCaughtUp = app.descendants(matching: .any)
            .matching(identifier: "upcoming.caught-up")
            .firstMatch
        assertStacked(
            firstCaughtUp,
            below: firstRow,
            "Caught up must stack below the row button at accessibility5 on an Upcoming row."
        )
    }

    /// Accessibility FIX item, not optional (staged review): Log other's
    /// picker is presented UI with its own accessibility tree — it needs the
    /// same audit coverage every other screen gets, not just a "the trigger
    /// button exists" check.
    ///
    /// This used to open a `confirmationDialog`, which on the OS this
    /// shipped against rendered as an anchored, translucent popover with no
    /// reachable Cancel control at all — `.presentationCompactAdaptation
    /// (.sheet)`, added to force the standard action-sheet presentation,
    /// didn't change that (confirmed live via an accessibility-tree dump:
    /// still a `Popover` container, no "Cancel" button anywhere, dismissal
    /// only through a `PopoverDismissRegion` VoiceOver can't discover —
    /// device report: "I can't get the voiceover to dismiss the picker").
    /// `LogOtherChannelSheet` replaces it with a `.sheet` this app controls
    /// outright, with a real, labeled Cancel button — this test is the
    /// assertion that would have caught the original defect, and its
    /// absence is why the `.presentationCompactAdaptation` fix shipped
    /// without actually fixing anything.
    ///
    /// "Picker is open" is detected on `cancel` itself, a leaf, not a
    /// container: an earlier version queried the `List`'s own identifier for
    /// this, and a live accessibility-tree dump showed that identifier
    /// resolving fine while `cancel` — placed as a trailing row *inside*
    /// that same `List` at the time — didn't exist in the tree at all
    /// (`List` is a lazy, virtualized `UICollectionView`; a row placed after
    /// all 13 channel rows is never scrolled into view by anything in this
    /// flow, so it's never instantiated). `LogOtherChannelSheet` now puts
    /// Cancel outside the `List` for exactly this reason — see its doc
    /// comment — which also makes it the right leaf to gate on here: no
    /// container identifier anywhere in that view for this test to depend
    /// on, and one query serves both "is it open" and the dismissal
    /// assertion below.
    @MainActor
    func testLogOtherChannelPickerPassesAudit() throws {
        let app = launchToOverdue()
        navigateToRow(
            identifier: "overdue.row",
            index: 0,
            sourceIdentifier: "screen.overdue",
            in: app
        )
        let logOther = app.descendants(matching: .any)["contact-detail.log-other"]
        XCTAssertTrue(logOther.waitForExistence(timeout: 10))

        // A single bare tap on `logOther` can still be dropped by the
        // simulator the same way row/tab taps can (the documented PR
        // #11/#12 flake this file's other navigation helpers all guard
        // against with bounded retries) — this one needs its own retry loop
        // since `navigate(...)` assumes the source screen disappears, which
        // a modal sheet over Contact Detail never does.
        let cancel = app.descendants(matching: .any)["contact-detail.log-other-cancel"]
        for attempt in 0..<3 {
            guard waitUntilLiveAndHittable(logOther) else { continue }
            activate(logOther, attempt: attempt)
            if cancel.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(cancel.exists, "Log other should open the channel picker.")
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)

        // The blocker this closes: a real, labeled, hittable Cancel control
        // that actually dismisses the picker — not a tap-outside region
        // VoiceOver never surfaces.
        XCTAssertTrue(waitUntilLiveAndHittable(cancel))
        activate(cancel, attempt: 0)
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10))
    }

    /// Pins what the app actually does after a Contact Detail Snooze, not
    /// just what `load()` does when called directly (unit-tested already):
    /// `ReminderRepository` writes have no `observeTracked()`-style push, so
    /// Overdue only notices a Detail-side Snooze through `.onAppear` firing
    /// again on the `NavigationStack` pop back to it.
    @MainActor
    func testSnoozeFromContactDetailReflectsOnReturnToOverdue() {
        let app = launchToOverdue()
        let subtitle = app.descendants(matching: .any)["screen.overdue"]
            .descendants(matching: .staticText).firstMatch
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10))
        let subtitleBefore = subtitle.label

        navigateToRow(
            identifier: "overdue.row",
            index: 0,
            sourceIdentifier: "screen.overdue",
            in: app
        )
        let snooze = app.descendants(matching: .any)["contact-detail.snooze"]
        XCTAssertTrue(snooze.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilLiveAndHittable(snooze))
        activate(snooze, attempt: 0)

        navigate(
            from: "screen.contact-detail",
            to: "screen.overdue",
            triggerDescription: "Overdue back button",
            in: app
        ) {
            app.navigationBars.buttons.element(boundBy: 0)
        }

        XCTAssertTrue(subtitle.waitForExistence(timeout: 10))
        // Something changed: `.onAppear` reloaded and the snoozed contact's
        // row is no longer counted. The exact count depends on the mock
        // fixture's other overdue contacts, so this asserts the subtitle
        // actually moved rather than pinning a specific number.
        XCTAssertNotEqual(
            subtitle.label,
            subtitleBefore,
            "Overdue's subtitle should reflect the Detail-side snooze after returning, not the stale pre-snooze count."
        )
    }
}
