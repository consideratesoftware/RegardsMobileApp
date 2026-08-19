import XCTest

/// Wiring, labeling, and layout coverage for Overdue's Caught up / Snooze
/// and Upcoming's Caught up — split from `ScreensAccessibilityTests.swift`
/// to keep that file's audit-per-screen shape focused. Coverage for the two
/// screens' presented surfaces (Log other picker, channel-preview alert,
/// the Detail-side-snooze regression) lives in
/// `ScreensAccessibilityTests+PresentedSurfaces.swift`, split out purely to
/// stay under the linter's file-length limit as this grew.
///
/// Round 12 (`ARCHITECTURE.md` R52) replaced Overdue/Upcoming's per-row
/// Caught up / Snooze *buttons* with native `List`/`.swipeActions`, and
/// replaced both screens' row tap — previously a push to Contact Detail —
/// with a native `.alert` that previews the channel action pending TF-08.
/// Every test below that referenced the old `overdue.caught-up` /
/// `overdue.snooze` / `upcoming.caught-up` identifiers was rewritten: those
/// identifiers no longer exist (a `.swipeActions` button has no stable
/// identifier of its own to query by until it's revealed), and the actions
/// themselves are no longer visible controls sitting in the row — they're
/// reached by a swipe gesture or, for a VoiceOver user, the rotor.
extension ScreensAccessibilityTests {

    /// XCUITest has no public API to enumerate an element's VoiceOver
    /// rotor "Actions" the way a person swiping through the rotor would —
    /// there is no `XCUIElement.customActions` or equivalent. What it can
    /// do, and what this test does: perform the same swipe gesture a
    /// sighted user would, reveal the identical `UISwipeActionsConfiguration`
    /// buttons the rotor also exposes (both are backed by the same
    /// `.swipeActions` closure), assert their label, and activate them —
    /// covering presence, labelling, and wiring, the parts that regress
    /// silently in a `List` migration. What it cannot do is assert that a
    /// VoiceOver *announcement* is spoken after activation — the simulator
    /// has no VoiceOver process (no speech, no focus cursor, no
    /// announcement queue) — that one question stays a device check.
    ///
    /// The gesture matters: `XCUIElement.swipeRight()`/`swipeLeft()` cover
    /// the element's full width at speed, which crosses `allowsFullSwipe`'s
    /// completion threshold and fires the action immediately rather than
    /// just revealing it (confirmed directly — an earlier version of this
    /// test using `swipeRight()` removed the row before ever asserting on
    /// the revealed button's label, then failed the *next* assertion for
    /// an unrelated-looking reason). A controlled partial drag — press,
    /// hold briefly, drag partway, release, via `revealLeadingSwipeAction`/
    /// `revealTrailingSwipeAction` below — reveals without completing.
    @MainActor
    func testOverdueRowActionsAreWiredAndLabeled() {
        let app = launchToOverdue()
        let plainRow = app.descendants(matching: .any)["overdue.row"]
        XCTAssertTrue(plainRow.waitForExistence(timeout: 10))
        let caughtUpRow = app.descendants(matching: .any)
            .matching(identifier: "overdue.row")
            .firstMatch

        assertRowIsOneOpaqueElement(caughtUpRow, contentDescription: "overdue")
        let caughtUpName = String(caughtUpRow.label.split(separator: ",").first ?? Substring(caughtUpRow.label))

        revealLeadingSwipeAction(on: caughtUpRow)
        let caughtUp = app.buttons.element(
            matching: NSPredicate(format: "label == %@", "Mark \(caughtUpName) caught up")
        )
        XCTAssertTrue(
            waitUntilLiveAndHittable(caughtUp, timeout: 5),
            "Swiping right should reveal a hittable Caught up action."
        )
        activate(caughtUp, attempt: 0)
        XCTAssertTrue(
            app.staticTexts[caughtUpName].waitForNonExistence(timeout: 5)
                || !app.descendants(matching: .any)
                    .matching(identifier: "overdue.row").allElementsBoundByIndex
                    .contains(where: { $0.label.hasPrefix(caughtUpName) }),
            "Activating Caught up should remove \(caughtUpName)'s row from Overdue."
        )

        // A fresh row, not the one just removed, for the trailing (Snooze)
        // check — the same over-trigger risk `revealTrailingSwipeAction`
        // avoids applies here too.
        let snoozeRow = app.descendants(matching: .any)
            .matching(identifier: "overdue.row")
            .firstMatch
        XCTAssertTrue(waitUntilLiveAndHittable(snoozeRow, timeout: 5))
        let snoozeName = String(snoozeRow.label.split(separator: ",").first ?? Substring(snoozeRow.label))

        revealTrailingSwipeAction(on: snoozeRow)
        let snooze = app.buttons.element(
            matching: NSPredicate(format: "label == %@", "Snooze \(snoozeName) 1 week")
        )
        XCTAssertTrue(
            waitUntilLiveAndHittable(snooze, timeout: 5),
            "Swiping left should reveal a hittable Snooze action."
        )
        activate(snooze, attempt: 0)
        XCTAssertTrue(
            !app.descendants(matching: .any)
                .matching(identifier: "overdue.row").allElementsBoundByIndex
                .contains(where: { $0.label.hasPrefix(snoozeName) }),
            "Activating Snooze should remove \(snoozeName)'s row from Overdue."
        )
    }

    /// Reveals a `List` row's leading (left-anchored) swipe action —
    /// Overdue's Caught up — with a controlled partial drag rather than
    /// `XCUIElement.swipeRight()`. See `testOverdueRowActionsAreWiredAnd
    /// Labeled`'s doc comment for why the full-width convenience gesture
    /// isn't safe to use here: it crosses `allowsFullSwipe`'s completion
    /// threshold and fires the action immediately.
    @MainActor
    private func revealLeadingSwipeAction(on row: XCUIElement) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// Trailing-edge counterpart to `revealLeadingSwipeAction` — Overdue's
    /// Snooze, Upcoming's is leading-only (see `UpcomingRow.body`'s doc
    /// comment for why it has no trailing action at all).
    @MainActor
    private func revealTrailingSwipeAction(on row: XCUIElement) {
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    /// Confirms a row is still one opaque accessibility element post-`List`
    /// migration (round 12 kept `.accessibilityElement(children: .ignore)`
    /// on both `OverdueRow` and `UpcomingRow`) — the trailing `ChannelGlyph`
    /// does not become its own competing element the way it briefly was
    /// before round 11 collapsed it to a decorative glyph, and the row's
    /// combined label still speaks the content `contentDescription` names
    /// (e.g. "overdue" for Overdue's how-overdue phrase). `children(matching:
    /// .any).count == 0` is the direct proof: an `.ignore`d container
    /// exposes no queryable child elements — a name `Text`, the avatar, or
    /// the glyph leaking through as a sibling would show up here.
    @MainActor
    private func assertRowIsOneOpaqueElement(_ row: XCUIElement, contentDescription: String) {
        XCTAssertTrue(
            row.label.contains(contentDescription),
            "The row's combined label should still speak its \(contentDescription) content."
        )
        XCTAssertEqual(
            row.children(matching: .any).count,
            0,
            "The row should expose no separately-queryable child elements — the trailing channel"
                + " glyph must stay decorative, not become a competing element inside the row."
        )
    }

    /// See `testOverdueRowActionsAreWiredAndLabeled`'s doc comment for what
    /// this test can and can't prove about rotor reachability.
    ///
    /// Upcoming gates Caught up to cadence rows only (`row.kind == .cadence`
    /// — unchanged by round 12, see `UpcomingRow.body`'s doc comment), and
    /// the fixture's first row is a birthday row with no swipe action at
    /// all. Post-round-12 (Sid's cadence-trim call — see
    /// `UpcomingRowState.accessibilityLabel`'s doc comment), a cadence row's
    /// label is exactly `"<name> at <time>"`, with no comma; an occasion
    /// row's label always has one (`"<name>, <occasion> at <time>"`). That
    /// distinction is what this test uses to find a cadence row rather than
    /// assuming a fixed index.
    @MainActor
    func testUpcomingRowActionIsWiredAndLabeled() {
        let app = launchToOverdue()
        navigateToTab(named: "Upcoming", from: "screen.overdue", to: "screen.upcoming", in: app)

        let plainRow = app.descendants(matching: .any)["upcoming.row"]
        XCTAssertTrue(plainRow.waitForExistence(timeout: 10))
        let rows = app.descendants(matching: .any)
            .matching(identifier: "upcoming.row")
            .allElementsBoundByIndex
        guard let cadenceRow = rows.first(where: { !$0.label.contains(",") }) else {
            XCTFail("Expected at least one cadence row (no comma in a post-round-12 label) in the Upcoming fixture.")
            return
        }

        assertRowIsOneOpaqueElement(cadenceRow, contentDescription: " at ")
        let name = cadenceRow.label.components(separatedBy: " at ").first ?? cadenceRow.label

        revealLeadingSwipeAction(on: cadenceRow)
        let caughtUp = app.buttons.element(
            matching: NSPredicate(format: "label == %@", "Mark \(name) caught up")
        )
        XCTAssertTrue(
            waitUntilLiveAndHittable(caughtUp, timeout: 5),
            "Swiping right on a cadence row should reveal a hittable Caught up action."
        )
        activate(caughtUp, attempt: 0)
        XCTAssertTrue(
            !app.descendants(matching: .any)
                .matching(identifier: "upcoming.row").allElementsBoundByIndex
                .contains(where: { $0.label.hasPrefix(name) }),
            "Activating Caught up should remove \(name)'s cadence row from Upcoming."
        )
    }

    /// Replaces the pre-round-12 "does not overlap at accessibility5" pair:
    /// that concern belonged to `caughtUpButton`/`snoozeButton`, custom
    /// icon-sized controls this same row laid out inline via
    /// `AccessibilityAdaptiveLayout`'s manual stacking. Swipe actions are
    /// system `UISwipeActionsConfiguration` buttons now — iOS lays them out
    /// itself, off to the side, never inline with row content, so there is
    /// nothing left for them to overlap. What's still worth confirming at
    /// accessibility5 is that Dynamic Type growth hasn't made either action
    /// unreachable or mislabeled once revealed.
    @MainActor
    func testOverdueRowActionsRemainLabeledAndHittableAtAccessibility5() {
        let app = launchToOverdue(dynamicTypeSize: "accessibility5")
        let plainRow = app.descendants(matching: .any)["overdue.row"]
        XCTAssertTrue(plainRow.waitForExistence(timeout: 10))
        let row = app.descendants(matching: .any)
            .matching(identifier: "overdue.row")
            .firstMatch

        // Partial reveal, not `swipeRight()`/`swipeLeft()` — see
        // `testOverdueRowActionsAreWiredAndLabeled`'s doc comment for why;
        // a partial drag doesn't complete `allowsFullSwipe`, so the row
        // survives both checks and no reset is needed between them.
        revealLeadingSwipeAction(on: row)
        let caughtUp = app.buttons.element(
            matching: NSPredicate(format: "label BEGINSWITH 'Mark ' AND label ENDSWITH ' caught up'")
        )
        XCTAssertTrue(waitUntilLiveAndHittable(caughtUp, timeout: 5))

        revealTrailingSwipeAction(on: row)
        let snooze = app.buttons.element(
            matching: NSPredicate(format: "label BEGINSWITH 'Snooze ' AND label ENDSWITH ' 1 week'")
        )
        XCTAssertTrue(waitUntilLiveAndHittable(snooze, timeout: 5))
    }

    /// See `testOverdueRowActionsRemainLabeledAndHittableAtAccessibility5`
    /// for why this is a labeled/hittable check now, not an overlap check.
    ///
    /// `List`'s lazy virtualization (see `assertRowsRemainStackedAt
    /// Accessibility5` in `ScreensAccessibilityTests+Contracts.swift`) means
    /// a single row is not guaranteed to exist at accessibility5 without a
    /// scroll, and the *first* cadence row specifically may be further down
    /// than that one scroll reaches — the fixture's first section starts
    /// with a birthday row. This bounds a scroll-and-search loop rather than
    /// assuming either "any row" or "the first cadence row" is already on
    /// screen.
    @MainActor
    func testUpcomingRowActionRemainsLabeledAndHittableAtAccessibility5() {
        let app = launchToOverdue(dynamicTypeSize: "accessibility5")
        navigateToTab(named: "Upcoming", from: "screen.overdue", to: "screen.upcoming", in: app)
        let upcomingScreen = app.descendants(matching: .any)["screen.upcoming"]

        var cadenceRow: XCUIElement?
        for _ in 0..<8 {
            let rows = app.descendants(matching: .any)
                .matching(identifier: "upcoming.row")
                .allElementsBoundByIndex
            if let match = rows.first(where: { !$0.label.contains(",") }) {
                cadenceRow = match
                break
            }
            upcomingScreen.swipeUp()
        }
        guard let cadenceRow else {
            XCTFail("Expected at least one cadence row in the Upcoming fixture at accessibility5.")
            return
        }

        revealLeadingSwipeAction(on: cadenceRow)
        let caughtUp = app.buttons.element(
            matching: NSPredicate(format: "label BEGINSWITH 'Mark ' AND label ENDSWITH ' caught up'")
        )
        XCTAssertTrue(waitUntilLiveAndHittable(caughtUp, timeout: 5))
    }
}
