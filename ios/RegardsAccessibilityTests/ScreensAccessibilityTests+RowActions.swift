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

        // On this simulator/OS, `confirmationDialog` renders as an
        // anchored popover rather than a bottom action sheet, and a
        // popover-style presentation drops the explicit `Button("Cancel",
        // role: .cancel)` row entirely — dismissal is tap-outside only
        // (confirmed by dumping the failure-state accessibility tree: the
        // "Log other channel" sheet and its 13 channel buttons are present,
        // no "Cancel" button anywhere). So the stable proof the sheet is up
        // is the dialog itself, queried by the title it's declared with,
        // not a Cancel row that may not exist. A single bare tap on
        // `logOther` can still be dropped by the simulator the same way
        // row/tab taps can (the documented PR #11/#12 flake this file's
        // other navigation helpers all guard against with bounded retries) —
        // this one needs its own retry loop since `navigate(...)` assumes
        // the source screen disappears, which a modal sheet over Contact
        // Detail never does.
        let channelPicker = app.sheets["Log other channel"]
        for attempt in 0..<3 {
            guard waitUntilLiveAndHittable(logOther) else { continue }
            activate(logOther, attempt: attempt)
            if channelPicker.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(channelPicker.exists, "Log other should open the channel picker.")
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories, suppressKnownPopoverGlassBleedThrough)

        // Dismiss by tapping outside the popover's bounds — left edge,
        // vertical middle, well clear of both the anchored card (x roughly
        // 81–321 of a 402pt-wide screen) and the status bar / Dynamic
        // Island exclusion zone near y=0, which can swallow a tap before it
        // reaches the app. Not a Cancel row: confirmed above that this
        // popover presentation doesn't expose one.
        let dismissRegion = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(dismissRegion.waitForExistence(timeout: 5))
        dismissRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        XCTAssertTrue(channelPicker.waitForNonExistence(timeout: 10))
    }

    /// `ios/docs/accessibility.md`'s "Known system-UI audit interruption"
    /// section already carves out one precedent for this exact message
    /// ("Potentially inaccessible text" against an OS "Ready for Apple
    /// Intelligence" banner), classified from the failed run's element
    /// identification plus its screenshot. `.elementDetection` issues on
    /// this popover don't offer that first proof — `issue.element` is `nil`
    /// for all four findings this dialog produces (confirmed by dumping
    /// every `XCUIAccessibilityAuditIssue` property in a debug run: `auditType`,
    /// `compactDescription`, and `detailedDescription` are populated,
    /// `element` is not — Xcode 26's `.elementDetection` audit doesn't
    /// attach an element handle to this finding at all). So this
    /// classification rests on the second kind of proof instead: source and
    /// screenshot.
    ///
    /// `ContactDetailScreen`'s channel rows are exactly
    /// `Button(channel.displayName) { ... }` inside a system
    /// `.confirmationDialog` — no custom drawing, no fixed font size, no
    /// image, nothing app code could style differently. On this
    /// simulator/OS a `confirmationDialog` with this many choices renders
    /// as an anchored, translucent "glass" popover rather than a bottom
    /// action sheet (see the Cancel-row note above), and that system
    /// material lets faint, blurred Contact Detail content from behind the
    /// dialog show through specific rows — most visibly the FaceTime row,
    /// where an xcresult screenshot from this exact test
    /// (`AF67B7AA-83EB-4E25-9A4A-C6E5ECE2ACBC.png`, run
    /// `TargetedRun-1786354772`) shows text-shaped blur bleeding through on
    /// both sides of the label. That bled-through content belongs to a
    /// different screen and was never meant to be read here; every element
    /// this dialog actually declares (title, each channel button) already
    /// carries a correct, non-empty accessibility label per the source
    /// above, so nothing legible is going unreported to VoiceOver. This
    /// reads as the audit's OCR-based text detection picking up backdrop
    /// blur through system-owned "Liquid Glass" chrome — not app content.
    /// Neither Dynamic Type nor a fixed size is the cause: this test never
    /// sets `REGARDS_UI_TEST_DYNAMIC_TYPE`, so it runs at the system
    /// default, and the bleed-through was still present.
    ///
    /// Scope stays as narrow as `structuralAuditCategories` itself: this
    /// filters only `.elementDetection` "Potentially inaccessible text"
    /// findings, only inside this one test's audit call. Every other audit
    /// type, and this same category on every other screen, still fails
    /// normally.
    ///
    /// `performAccessibilityAuditWithAuditTypes:issueHandler:error:`'s
    /// header doc: "return YES to handle it yourself" — the handler's
    /// `Bool` means *suppress*, not *keep failing*, which is the inverse of
    /// the intuitive reading. `true` here means "handled, don't record."
    @MainActor
    private func suppressKnownPopoverGlassBleedThrough(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.auditType == .elementDetection
            && issue.compactDescription == "Potentially inaccessible text"
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
