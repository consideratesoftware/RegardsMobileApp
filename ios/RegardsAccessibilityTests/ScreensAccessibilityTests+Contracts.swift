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
        assertStacked(title, below: action, "The title must stack below the nav action.")
        assertStacked(subtitle, below: title, "The subtitle must stack below the title.")

        let overdueSegment = app.descendants(matching: .any)["regards-segment.overdue"]
        let upcomingSegment = app.descendants(matching: .any)["regards-segment.upcoming"]
        XCTAssertTrue(overdueSegment.waitForExistence(timeout: 10))
        XCTAssertTrue(upcomingSegment.waitForExistence(timeout: 10))
        assertStacked(
            upcomingSegment,
            below: overdueSegment,
            "Accessibility-sized segment options must stack without overlap."
        )

        let digestLead = app.descendants(matching: .any)["overdue.digest-lead"]
        let digestTime = app.descendants(matching: .any)["overdue.digest-time"]
        XCTAssertTrue(digestLead.waitForExistence(timeout: 10))
        XCTAssertTrue(digestTime.waitForExistence(timeout: 10))
        assertStacked(
            digestTime,
            below: digestLead,
            "The digest time must stack below its lead at accessibility sizes."
        )

        navigateToTab(
            named: "Upcoming",
            from: "screen.overdue",
            to: "screen.upcoming",
            in: app
        )
        let plainUpcomingRow = app.descendants(matching: .any)["upcoming.row"]
        XCTAssertTrue(plainUpcomingRow.waitForExistence(timeout: 10))
        let upcomingRows = app.descendants(matching: .any)
            .matching(identifier: "upcoming.row")
            .allElementsBoundByIndex
        guard upcomingRows.count >= 2 else {
            XCTFail("Upcoming should expose at least two rows for overlap verification.")
            return
        }
        assertStacked(
            upcomingRows[1],
            below: upcomingRows[0],
            "Upcoming rows must remain distinct at accessibility sizes."
        )
        navigateToTab(
            named: "Overdue",
            from: "screen.upcoming",
            to: "screen.overdue",
            in: app
        )

        app.descendants(matching: .any)["screen.overdue"].swipeUp()
        let plainOverdueRow = app.descendants(matching: .any)["overdue.row"]
        XCTAssertTrue(plainOverdueRow.waitForExistence(timeout: 10))
        let firstOverdueRow = app.descendants(matching: .any)
            .matching(identifier: "overdue.row")
            .firstMatch
        XCTAssertTrue(
            waitUntilLiveAndHittable(firstOverdueRow, timeout: 3),
            "The first overdue row should be visible and hittable after scrolling."
        )
        let plainFirstChannel = app.descendants(matching: .any)["overdue.channel-unavailable"]
        XCTAssertTrue(plainFirstChannel.waitForExistence(timeout: 10))
        let firstChannel = app.descendants(matching: .any)
            .matching(identifier: "overdue.channel-unavailable")
            .firstMatch
        assertStacked(
            firstChannel,
            below: firstOverdueRow,
            "The channel pill must stack below the contact row at accessibility sizes."
        )
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
        assertStacked(snooze, below: caughtUp, "Snooze must stack below Caught up.")
        assertStacked(logOther, below: snooze, "Log other must stack below Snooze.")

        let channelSummary = app.descendants(matching: .any)["contact-detail.channel-summary"]
        let channelChange = app.descendants(matching: .any)["contact-detail.channel-change-unavailable"]
        XCTAssertTrue(channelSummary.waitForExistence(timeout: 10))
        XCTAssertTrue(channelChange.waitForExistence(timeout: 10))
        assertStacked(
            channelChange,
            below: channelSummary,
            "The accessibility-sized channel action must stack below its summary."
        )

        let cadenceValue = app.descendants(matching: .any)["contact-detail.detail-value-every"]
        let cadenceChange = app.descendants(matching: .any)["contact-detail.cadence-change-unavailable"]
        XCTAssertTrue(cadenceValue.waitForExistence(timeout: 10))
        XCTAssertTrue(cadenceChange.waitForExistence(timeout: 10))
        assertStacked(
            cadenceChange,
            below: cadenceValue,
            "The cadence action must stack below its value at accessibility sizes."
        )

        navigate(
            from: "screen.contact-detail",
            to: "screen.edit-contact",
            triggerDescription: "Edit",
            in: app
        ) {
            editButton(in: app)
        }
        let firstName = app.descendants(matching: .any)["edit-contact.field-first"]
        let lastName = app.descendants(matching: .any)["edit-contact.field-last"]
        XCTAssertTrue(firstName.waitForExistence(timeout: 10))
        XCTAssertTrue(lastName.waitForExistence(timeout: 10))
        assertStacked(
            lastName,
            below: firstName,
            "Edit Contact fields must remain distinct at accessibility sizes."
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
