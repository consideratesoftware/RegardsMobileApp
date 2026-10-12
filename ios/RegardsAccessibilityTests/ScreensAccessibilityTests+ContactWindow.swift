import XCTest

/// TF-05 slice 4: the per-contact reminder-window row on Contact Detail and
/// the override editor it opens, on the mock runtime (every seeded contact is
/// tracked with a cadence).
///
/// ASSUMED identifiers, not yet confirmed by the slice 4 engineer: the row's
/// Change button `contact-detail.window-change`, and the row's value texts
/// "Your default" / "Custom". The editor's own ids (`screen.reminder-windows`,
/// `reminder-windows.save`, `reminder-windows.use-default`,
/// `reminder-windows.horizon-7`) come from slice 3.
extension ScreensAccessibilityTests {

    private static let changeWindowIdentifier = "contact-detail.window-change"

    @MainActor
    private func openOverrideEditor(in app: XCUIApplication) {
        let change = app.buttons[Self.changeWindowIdentifier]
        XCTAssertTrue(change.waitForExistence(timeout: 10), "Contact Detail should offer a reminder-window row.")
        change.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.reminder-windows"].waitForExistence(timeout: 10),
            "Change should open the override editor."
        )
    }

    @MainActor
    func testContactWindowOverrideEditorPassesAudit() throws {
        let app = launchToContactDetailFromContacts()
        openOverrideEditor(in: app)

        // Override mode edits days, ranges and quiet hours only (I3).
        XCTAssertTrue(app.buttons["Sunday"].waitForExistence(timeout: 5), "The days section should show.")
        XCTAssertFalse(app.buttons["reminder-windows.horizon-7"].exists, "The horizon section must be hidden.")
        XCTAssertFalse(app.staticTexts["Upcoming horizon"].exists)
        XCTAssertFalse(app.staticTexts["Occasion notifications"].exists, "The occasion section must be hidden.")
        XCTAssertFalse(
            app.datePickers.matching(NSPredicate(format: "label BEGINSWITH 'Morning-of time'")).firstMatch.exists
        )
        XCTAssertFalse(
            app.buttons["reminder-windows.use-default"].exists,
            "A contact with no stored override has nothing to clear."
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// Row state follows the override: "Your default" -> save -> "Custom" ->
    /// "Use my default window" -> "Your default".
    @MainActor
    func testContactWindowRowFollowsOverride() throws {
        let app = launchToContactDetailFromContacts()
        XCTAssertTrue(app.staticTexts["Your default"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Custom"].exists)

        // Change -> edit a day -> Save.
        openOverrideEditor(in: app)
        let sunday = app.buttons["Sunday"]
        XCTAssertTrue(sunday.waitForExistence(timeout: 5))
        let before = sunday.value as? String
        sunday.tap()
        XCTAssertNotEqual(sunday.value as? String, before, "The day pill should toggle.")
        app.buttons["reminder-windows.save"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.contact-detail"].waitForExistence(timeout: 10),
            "A successful save should return to Contact Detail."
        )
        XCTAssertTrue(app.staticTexts["Custom"].waitForExistence(timeout: 5), "The row should now read Custom.")
        XCTAssertFalse(app.staticTexts["Your default"].exists)

        // Reopen -> the editor offers the reset -> Use my default window.
        openOverrideEditor(in: app)
        let useDefault = app.buttons["reminder-windows.use-default"]
        XCTAssertTrue(useDefault.waitForExistence(timeout: 5), "A stored override should offer Use my default window.")
        useDefault.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["screen.contact-detail"].waitForExistence(timeout: 10),
            "Using the default window should return to Contact Detail."
        )
        XCTAssertTrue(app.staticTexts["Your default"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Custom"].exists)
    }

    /// An override saved for the first contact leaves the second contact's
    /// row at "Your default".
    @MainActor
    func testContactWindowOverrideDoesNotShowOnOtherContacts() throws {
        let app = launchToContactDetailFromContacts()
        openOverrideEditor(in: app)
        let sunday = app.buttons["Sunday"]
        XCTAssertTrue(sunday.waitForExistence(timeout: 5))
        sunday.tap()
        app.buttons["reminder-windows.save"].tap()
        XCTAssertTrue(app.staticTexts["Custom"].waitForExistence(timeout: 10))

        app.buttons["BackButton"].tap()
        let contacts = app.descendants(matching: .any)["screen.contacts"]
        XCTAssertTrue(contacts.waitForExistence(timeout: 10))
        let secondRow = contacts.descendants(matching: .button).element(boundBy: 1)
        XCTAssertTrue(waitUntilLiveAndHittable(secondRow, timeout: 10))
        activate(secondRow, attempt: 0)

        XCTAssertTrue(app.descendants(matching: .any)["screen.contact-detail"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["Your default"].waitForExistence(timeout: 5),
            "A different contact must keep following the global window."
        )
        XCTAssertFalse(app.staticTexts["Custom"].exists)
    }
}
