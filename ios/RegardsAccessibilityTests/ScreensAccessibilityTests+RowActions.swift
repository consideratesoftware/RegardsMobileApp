import XCTest

/// Wiring, labeling, and layout coverage for the §14 PR22 row controls
/// (Overdue's Caught up / Snooze, Upcoming's Caught up) and Contact Detail's
/// Log other channel picker — split from `ScreensAccessibilityTests.swift`
/// to keep that file's audit-per-screen shape focused.
extension ScreensAccessibilityTests {

    @MainActor
    func testOverdueRowActionsAreWiredAndLabeled() {
        let app = launchToOverdue()
        let firstCaughtUp = app.descendants(matching: .any)
            .matching(identifier: "overdue.caught-up")
            .firstMatch
        let firstSnooze = app.descendants(matching: .any)
            .matching(identifier: "overdue.snooze")
            .firstMatch
        XCTAssertTrue(firstCaughtUp.waitForExistence(timeout: 10))
        XCTAssertTrue(firstSnooze.waitForExistence(timeout: 10))

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
        let firstCaughtUp = app.descendants(matching: .any)
            .matching(identifier: "upcoming.caught-up")
            .firstMatch
        XCTAssertTrue(firstCaughtUp.waitForExistence(timeout: 10))
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
        let firstCaughtUp = app.descendants(matching: .any)
            .matching(identifier: "overdue.caught-up")
            .firstMatch
        let firstSnooze = app.descendants(matching: .any)
            .matching(identifier: "overdue.snooze")
            .firstMatch
        XCTAssertTrue(firstCaughtUp.waitForExistence(timeout: 10))
        XCTAssertTrue(firstSnooze.waitForExistence(timeout: 10))
        assertStacked(
            firstSnooze,
            below: firstCaughtUp,
            "Snooze must stack below Caught up at accessibility5 on an Overdue row."
        )
    }

    /// Accessibility FIX item, not optional (staged review): Log other's
    /// `confirmationDialog` is new, presented UI with its own accessibility
    /// tree — it needs the same audit coverage every other screen gets, not
    /// just a "the trigger button exists" check.
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
        XCTAssertTrue(waitUntilLiveAndHittable(logOther))
        activate(logOther, attempt: 0)

        // `confirmationDialog` renders as a system action sheet; "Cancel" is
        // always present and is the most stable proof the sheet is up.
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)

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
