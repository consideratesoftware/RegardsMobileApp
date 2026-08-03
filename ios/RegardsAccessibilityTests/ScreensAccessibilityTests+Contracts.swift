import XCTest

extension ScreensAccessibilityTests {
    @MainActor
    func testAccessibility5AdaptiveContentDoesNotOverlap() {
        let app = launchToOverdue(dynamicTypeSize: "accessibility5")
        let action = app.descendants(matching: .any)["regards-nav.right-action"]
        let title = app.descendants(matching: .any)["regards-nav.title"]
        let subtitle = app.descendants(matching: .any)["regards-nav.subtitle"]

        XCTAssertTrue(action.waitForExistence(timeout: 10))
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(subtitle.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(title.frame.minY, action.frame.maxY)
        XCTAssertGreaterThanOrEqual(subtitle.frame.minY, title.frame.maxY)

        app.descendants(matching: .any)["screen.overdue"].swipeUp()
        navigateToRow(
            identifier: "overdue.row",
            index: 0,
            sourceIdentifier: "screen.overdue",
            in: app
        )
        let caughtUp = app.descendants(matching: .any)["contact-detail.caught-up-unavailable"]
        let snooze = app.descendants(matching: .any)["contact-detail.snooze-unavailable"]
        let logOther = app.descendants(matching: .any)["contact-detail.log-other-unavailable"]
        XCTAssertTrue(caughtUp.waitForExistence(timeout: 10))
        XCTAssertTrue(snooze.waitForExistence(timeout: 10))
        XCTAssertTrue(logOther.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(snooze.frame.minY, caughtUp.frame.maxY)
        XCTAssertGreaterThanOrEqual(logOther.frame.minY, snooze.frame.maxY)

        let channelSummary = app.descendants(matching: .any)["contact-detail.channel-summary"]
        let channelChange = app.descendants(matching: .any)["contact-detail.channel-change-unavailable"]
        XCTAssertTrue(channelSummary.waitForExistence(timeout: 10))
        XCTAssertTrue(channelChange.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(
            channelChange.frame.minY,
            channelSummary.frame.maxY,
            "The accessibility-sized channel action must stack below its summary."
        )
    }

    @MainActor
    func testUnavailableActionsAreDescribedAndNoninteractive() {
        let app = launchToOverdue()
        assertUnavailableElement(
            identifier: "overdue.channel-unavailable",
            expectedLabel: nil,
            in: app
        )
        navigateToRow(
            identifier: "overdue.row",
            index: 0,
            sourceIdentifier: "screen.overdue",
            in: app
        )

        let unavailableElements = [
            ("contact-detail.open-channel-unavailable", "Open WhatsApp, unavailable"),
            ("contact-detail.caught-up-unavailable", "Caught up, unavailable"),
            ("contact-detail.snooze-unavailable", "Snooze 1 wk, unavailable"),
            ("contact-detail.log-other-unavailable", "Log other, unavailable"),
            ("contact-detail.cadence-change-unavailable", "Change, unavailable"),
            ("contact-detail.channel-change-unavailable", "Change, unavailable"),
        ]
        for (identifier, expectedLabel) in unavailableElements {
            assertUnavailableElement(
                identifier: identifier,
                expectedLabel: expectedLabel,
                in: app
            )
        }
    }
}
