import XCTest

/// TF-05 slice 3: the live Reminder windows editor, driven through Settings
/// on the mock runtime (global window: weekdays, Asia/Kolkata, 14-day horizon).
///
/// Identifiers (from the screen's work in progress): day pills are Buttons
/// labelled with the full day name and valued "allowed" / "not allowed";
/// horizon choices are `reminder-windows.horizon-7|14|30`; the toolbar button
/// is `reminder-windows.save`; the inline error is `reminder-windows.error`.
/// `testContactWindowOverrideEditorPassesAudit` waits for slice 4's Contact
/// Detail entry point.
extension ScreensAccessibilityTests {

    @MainActor
    private func openReminderWindows() -> XCUIApplication {
        let app = launchToSettings()
        navigateFromSettings(
            triggerIdentifier: "settings.reminder-windows",
            to: "screen.reminder-windows",
            in: app
        )
        return app
    }

    @MainActor
    func testReminderWindowEditReshapesUpcoming() throws {
        let app = openReminderWindows()
        let horizon = app.buttons["reminder-windows.horizon-7"]
        XCTAssertTrue(horizon.waitForExistence(timeout: 5), "The horizon control should be on the editor.")
        horizon.tap()
        let save = app.buttons["reminder-windows.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        let settings = app.descendants(matching: .any)["screen.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "A successful save should dismiss the editor.")
        navigateToTab(named: "Upcoming", from: "screen.settings", to: "screen.upcoming", in: app)
        XCTAssertTrue(
            app.staticTexts["Next 7 days"].waitForExistence(timeout: 5),
            "Upcoming should show the saved 7-day horizon without a relaunch."
        )
    }

    @MainActor
    func testNoDaysSaveShowsInlineError() throws {
        let app = openReminderWindows()
        for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"] {
            let pill = app.buttons[day]
            XCTAssertTrue(pill.waitForExistence(timeout: 5), "\(day) pill should exist.")
            pill.tap()
            XCTAssertEqual(pill.value as? String, "not allowed", "\(day) should toggle off.")
        }
        app.buttons["reminder-windows.save"].tap()

        let error = app.descendants(matching: .any)["reminder-windows.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), "Saving with no days should show an inline error.")
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.reminder-windows"].exists,
            "A refused save should keep the editor open."
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }
}
