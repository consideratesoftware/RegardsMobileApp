import XCTest

/// TF-05 slice 3: the live Reminder windows editor, driven through Settings
/// on the mock runtime (global window: weekdays, Asia/Kolkata, 14-day horizon).
///
/// Identifiers: day pills are Buttons labelled with the full day name and
/// valued "allowed" / "not allowed"; horizon choices are
/// `reminder-windows.horizon-7|14|30`; the toolbar button is
/// `reminder-windows.save`; the inline error is `reminder-windows.error`.
/// The override editor opened from Contact Detail is covered in
/// `ScreensAccessibilityTests+ContactWindow.swift`.
extension ScreensAccessibilityTests {

    @MainActor
    private func openReminderWindows(extraLaunchEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = launchToSettings(extraLaunchEnvironment: extraLaunchEnvironment)
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

    /// Edits a range time through the real DatePicker and checks the stored
    /// value. The picker runs on a fixed UTC reference, so it must read the
    /// stored 22:00 as "10:00 PM" before any edit: without
    /// `.environment(\.timeZone, .gmt)` it reads in the device zone and shows
    /// another hour. The launch sets TZ to America/Los_Angeles so that holds
    /// on a UTC host as well.
    @MainActor
    func testReminderWindowPickerStoresTheEditedTime() throws {
        // TZ pins the app's zone to one that is never UTC, so a missing
        // `.gmt` pin is caught on UTC CI runners too (the host zone is not
        // what decides it).
        let app = openReminderWindows(extraLaunchEnvironment: ["TZ": "America/Los_Angeles"])
        // Wait on a plain identifier query; the predicate-derived time
        // buttons are then read with `.exists` only.
        XCTAssertTrue(app.buttons["reminder-windows.add-range"].waitForExistence(timeout: 5))
        let rangeEnd = rangeTimeButton("Range 2 end", in: app)
        XCTAssertTrue(rangeEnd.exists, "Range 2 end should be on the editor.")
        XCTAssertEqual(normalizedTime(rangeEnd), "10:00 PM", "The stored 22:00 must read as 10:00 PM.")

        rangeEnd.tap()
        let hourWheel = app.pickerWheels.element(boundBy: 0)
        XCTAssertTrue(hourWheel.waitForExistence(timeout: 5), "The time picker should open.")
        hourWheel.adjust(toPickerWheelValue: "9")
        app.buttons["PopoverDismissRegion"].tap()
        XCTAssertEqual(normalizedTime(rangeEnd), "9:00 PM")

        app.buttons["reminder-windows.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 10))
        navigateFromSettings(
            triggerIdentifier: "settings.reminder-windows",
            to: "screen.reminder-windows",
            in: app
        )
        XCTAssertTrue(app.buttons["reminder-windows.add-range"].waitForExistence(timeout: 5))
        let reopened = rangeTimeButton("Range 2 end", in: app)
        XCTAssertTrue(reopened.exists, "Range 2 end should be on the reopened editor.")
        XCTAssertEqual(normalizedTime(reopened), "9:00 PM", "The saved 21:00 should be what the editor loads.")
    }

    @MainActor
    private func rangeTimeButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.datePickers.matching(NSPredicate(format: "label BEGINSWITH %@", title))
            .firstMatch.buttons["Time Picker"]
    }

    /// The formatted value uses a narrow no-break space before AM/PM on newer systems.
    @MainActor
    private func normalizedTime(_ element: XCUIElement) -> String {
        ((element.value as? String) ?? "").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// The day summary describes the chosen days. Monday plus Saturday is
    /// neither "Weekends only." nor "Any day."; weekdays plus Saturday is not
    /// "Any day." The summary copy itself is the screen's; these check the two
    /// wrong answers do not appear.
    @MainActor
    func testDaySummaryDoesNotMislabelMixedDays() throws {
        let app = openReminderWindows()
        XCTAssertTrue(app.buttons["reminder-windows.add-range"].waitForExistence(timeout: 5))
        func toggle(_ names: [String]) {
            for name in names { app.buttons[name].tap() }
        }

        // Weekdays (the mock default) -> Monday plus Saturday.
        toggle(["Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"])
        XCTAssertEqual(app.buttons["Monday"].value as? String, "allowed")
        XCTAssertEqual(app.buttons["Saturday"].value as? String, "allowed")
        XCTAssertEqual(app.buttons["Tuesday"].value as? String, "not allowed")
        XCTAssertFalse(app.staticTexts["Weekends only."].exists, "Monday plus Saturday is not weekends only.")
        XCTAssertFalse(app.staticTexts["Any day."].exists)
        // The summary names the chosen days.
        let namesBoth = NSPredicate(format: "label CONTAINS 'Monday' AND label CONTAINS 'Saturday'")
        XCTAssertTrue(
            app.staticTexts.matching(namesBoth).firstMatch.exists,
            "The summary should name Monday and Saturday."
        )

        // Weekdays plus Saturday.
        toggle(["Tuesday", "Wednesday", "Thursday", "Friday"])
        XCTAssertEqual(app.buttons["Friday"].value as? String, "allowed")
        XCTAssertFalse(app.staticTexts["Any day."].exists, "Weekdays plus Saturday is not every day.")
        XCTAssertFalse(app.staticTexts["Weekends only."].exists)
    }

    /// At the largest Dynamic Type size each day is a full-width row, not a
    /// circle: the rows must still be buttons with their allowed value, at
    /// least 44pt tall, stacked top to bottom, and pass the audit.
    @MainActor
    func testReminderWindowsEditorAtAccessibility5() throws {
        let app = openReminderWindows(extraLaunchEnvironment: ["REGARDS_UI_TEST_DYNAMIC_TYPE": "accessibility5"])
        try assertDayRowsStackedAtAccessibility5(in: app)
    }

    /// The day rows on the open editor, global or override. Shared by the
    /// global and contact-override accessibility5 tests so both targets get
    /// the same checks.
    @MainActor
    func assertDayRowsStackedAtAccessibility5(in app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["Sunday"].waitForExistence(timeout: 10))
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let weekdays: Set<String> = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
        for name in names {
            let row = app.buttons[name]
            XCTAssertTrue(row.exists, "\(name) should be a button.")
            XCTAssertEqual(
                row.value as? String, weekdays.contains(name) ? "allowed" : "not allowed",
                "\(name) should expose its allowed state as its value."
            )
            XCTAssertGreaterThanOrEqual(row.frame.height.rounded(), 44, "\(name) needs a 44pt touch target.")
        }
        for (upper, lower) in zip(names, names.dropFirst()) {
            assertStacked(app.buttons[lower], below: app.buttons[upper], "\(lower) should sit below \(upper).")
        }
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// Save is in the toolbar, so the user is usually scrolled away from the
    /// inline error when a refusal happens. The banner must be brought into
    /// view and reachable, not left offscreen.
    @MainActor
    func testRefusalBannerIsHittableWhenScrolledAway() throws {
        let app = openReminderWindows()
        XCTAssertTrue(app.buttons["Monday"].waitForExistence(timeout: 10))
        for day in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"] {
            app.buttons[day].tap() // leaves no day selected, so a save is refused
        }
        let horizon = app.buttons["reminder-windows.horizon-30"]
        for _ in 0..<6 where !horizon.isHittable {
            app.descendants(matching: .any)["screen.reminder-windows"].swipeUp()
        }
        XCTAssertTrue(horizon.isHittable, "The editor should be scrolled to the bottom before saving.")

        app.buttons["reminder-windows.save"].tap()

        let banner = app.descendants(matching: .any)["reminder-windows.error"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "A refused save should show the inline error.")
        XCTAssertTrue(
            waitUntilLiveAndHittable(banner, timeout: 5),
            "The error banner should be scrolled into view and hittable."
        )
    }
}
