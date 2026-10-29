import XCTest

/// The starter-contacts picker, reached from Settings ("Choose people to keep
/// in touch with", TF-11 slice 2, §10.8). The mock launch has every contact
/// already tracked and no untracked one to pick, so the audits there only
/// prove the screen is reachable and well formed. The selection flows run on
/// the first-launch fixture, which imports one untracked contact (Leia
/// Organa) into a fresh in-memory store.
///
/// The UI test target can't import the app module, so the identifiers repeat
/// the ones the screens set.
extension ScreensAccessibilityTests {
    private static let chooseStartersRowID = "settings.choose-starters"
    private static let starterScreenID = "screen.starter-contacts"
    private static let starterDoneID = "starter.done"
    private static let leiaRowID = "starter.contact.Leia Organa"
    private static let leiaCadenceID = "starter.cadence.Leia Organa"

    @MainActor
    private func openStarterPicker(from app: XCUIApplication) {
        navigateFromSettings(
            triggerIdentifier: Self.chooseStartersRowID,
            to: Self.starterScreenID,
            in: app
        )
    }

    /// A fresh store with one imported, untracked contact, opened on Settings.
    @MainActor
    private func launchFirstLaunchToSettings(dynamicTypeSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--regards-first-launch-runtime")
        if let dynamicTypeSize {
            app.launchEnvironment["REGARDS_UI_TEST_DYNAMIC_TYPE"] = dynamicTypeSize
        }
        app.launch()

        let allow = app.buttons["onboarding.allow-contacts"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10), "A fresh launch should stop at the Contacts pre-prompt.")
        allow.tap()
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        XCTAssertTrue(overdue.waitForExistence(timeout: 10), "The import should reveal the tabs.")
        navigateToTab(named: "Settings", from: "screen.overdue", to: "screen.settings", in: app)
        return app
    }

    @MainActor
    private func leiaRow(in app: XCUIApplication) -> XCUIElement {
        let row = app.buttons[Self.leiaRowID]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The imported contact should be offered.")
        return row
    }

    @MainActor
    func testSettingsChooseStartersPassesAudit() throws {
        let app = launchToSettings()

        openStarterPicker(from: app)

        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testSettingsChooseStartersPassesAuditAtAccessibility5() throws {
        let app = launchToSettings(dynamicTypeSize: "accessibility5")

        openStarterPicker(from: app)

        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// With a contact picked, the cadence menu is on screen too. The mock
    /// launch can't show that row, because no contact there starts unpicked.
    @MainActor
    func testStarterPickerWithAPickedContactPassesAudit() throws {
        let app = launchFirstLaunchToSettings()
        openStarterPicker(from: app)

        leiaRow(in: app).tap()

        XCTAssertTrue(
            app.descendants(matching: .any)[Self.leiaCadenceID].waitForExistence(timeout: 10),
            "A picked contact should show its cadence menu."
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testStarterPickerWithAPickedContactPassesAuditAtAccessibility5() throws {
        let app = launchFirstLaunchToSettings(dynamicTypeSize: "accessibility5")
        openStarterPicker(from: app)

        leiaRow(in: app).tap()

        XCTAssertTrue(app.descendants(matching: .any)[Self.leiaCadenceID].waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// Every control on the screen must say what it does: a button, field, or
    /// menu with an empty label is announced as just "button". Picks the
    /// contact first so the cadence menu is counted.
    @MainActor
    func testStarterPickerControlsAllHaveLabels() throws {
        let app = launchFirstLaunchToSettings()
        openStarterPicker(from: app)
        leiaRow(in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)[Self.leiaCadenceID].waitForExistence(timeout: 10))

        let controls = app.buttons.allElementsBoundByIndex
            + app.searchFields.allElementsBoundByIndex
            + app.switches.allElementsBoundByIndex
            + app.textFields.allElementsBoundByIndex
        for control in controls {
            XCTAssertFalse(
                control.label.trimmingCharacters(in: .whitespaces).isEmpty,
                "A control has no VoiceOver label: \(control.debugDescription)"
            )
        }
        // The contact row, Done, and the search field at the least; a screen
        // that exposed nothing would pass the loop above vacuously.
        XCTAssertTrue(app.buttons[Self.leiaRowID].exists)
        XCTAssertTrue(app.buttons[Self.starterDoneID].exists)
        XCTAssertEqual(app.buttons[Self.starterDoneID].label, "Done")
        XCTAssertEqual(app.buttons[Self.leiaRowID].label, "Leia Organa")
    }

    /// Done writes nothing when nothing changed, so it must not look
    /// tappable: an enabled button that does nothing is an inert control.
    @MainActor
    func testStarterPickerDoneIsDisabledUntilSomethingIsPicked() throws {
        let app = launchFirstLaunchToSettings()
        openStarterPicker(from: app)
        let done = app.buttons[Self.starterDoneID]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertFalse(done.isEnabled, "Done has nothing to save before a pick.")

        leiaRow(in: app).tap()

        XCTAssertTrue(done.isEnabled, "Done should enable once a contact is picked.")
    }

    /// Done must write, leave the screen, and show up the next time the picker
    /// opens: the contact comes back already picked.
    @MainActor
    func testStarterPickerDoneTracksTheChosenContactAndReopensPicked() throws {
        let app = launchFirstLaunchToSettings()
        openStarterPicker(from: app)
        let leia = leiaRow(in: app)
        XCTAssertFalse(leia.isSelected, "Nothing is picked before the first tap.")

        leia.tap()
        XCTAssertTrue(leia.isSelected, "Tapping a row should pick it.")
        app.buttons[Self.starterDoneID].tap()

        let settings = app.descendants(matching: .any)["screen.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Done should return to Settings.")
        XCTAssertTrue(app.descendants(matching: .any)[Self.starterScreenID].waitForNonExistence(timeout: 10))

        openStarterPicker(from: app)
        XCTAssertTrue(leiaRow(in: app).isSelected, "A saved starter should come back picked.")
    }

    /// The saved cadence must reach All Contacts without a relaunch. The row
    /// shows no cadence for an untracked contact, so "every 2 weeks" (the
    /// default pick) can only come from the save.
    @MainActor
    func testStarterPickerDoneShowsTheCadenceInAllContacts() throws {
        let app = launchFirstLaunchToSettings()
        openStarterPicker(from: app)
        leiaRow(in: app).tap()
        app.buttons[Self.starterDoneID].tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.settings"].waitForExistence(timeout: 10))

        navigateToTab(named: "Contacts", from: "screen.settings", to: "screen.contacts", in: app)

        XCTAssertTrue(app.staticTexts["Leia Organa"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["every 2 weeks"].waitForExistence(timeout: 10),
            "All Contacts should show the cadence saved from Settings."
        )
    }

    /// Leaving through Back must not save: Settings has no Skip button, and a
    /// pick that was never confirmed must not survive.
    @MainActor
    func testStarterPickerBackWithoutDoneDoesNotSavePicks() throws {
        let app = launchFirstLaunchToSettings()
        openStarterPicker(from: app)
        leiaRow(in: app).tap()

        navigate(
            from: Self.starterScreenID,
            to: "screen.settings",
            triggerDescription: "Settings back button",
            in: app
        ) {
            app.navigationBars.buttons.element(boundBy: 0)
        }
        openStarterPicker(from: app)

        XCTAssertFalse(leiaRow(in: app).isSelected, "An unconfirmed pick must not be saved.")
    }
}
