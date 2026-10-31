import XCTest

/// The Settings Contacts access row (TF-11 slice 4, R14's re-entry clause).
/// The mock launch has no Contacts source, so it shows no row. These tests use
/// the first-launch fixture instead, whose source is scripted to deny at
/// launch (the row offers iOS Settings) or to grant (the row is status text).
/// Restricted, limited and not determined are covered by
/// `SettingsContactsRowTests`; the fixture has no way to reach them.
///
/// The UI test target can't import the app module, so the identifiers repeat
/// the ones the row sets.
extension ScreensAccessibilityTests {
    private static let contactsRowID = "settings.contacts-access"

    /// Fresh install, Contacts denied before launch, browse-only, then
    /// Settings. At accessibility5 the Continue button can sit below the fold,
    /// so a tap that didn't leave onboarding is repeated once.
    @MainActor
    private func launchDeniedToSettings(dynamicTypeSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--regards-first-launch-runtime")
        app.launchEnvironment["REGARDS_UI_TEST_CONTACTS_OUTCOME"] = "denied-at-launch"
        if let dynamicTypeSize {
            app.launchEnvironment["REGARDS_UI_TEST_DYNAMIC_TYPE"] = dynamicTypeSize
        }
        app.launch()

        let browse = app.buttons["onboarding.continue-without-contacts"]
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        XCTAssertTrue(
            browse.waitForExistence(timeout: 10),
            "A denied launch should offer to continue without contacts."
        )
        browse.tap()
        if !overdue.waitForExistence(timeout: 5) {
            XCTAssertTrue(browse.exists)
            browse.tap()
        }
        XCTAssertTrue(overdue.waitForExistence(timeout: 10), "Continuing without contacts should reveal the tabs.")
        navigateToTab(named: "Settings", from: "screen.overdue", to: "screen.settings", in: app)
        return app
    }

    @MainActor
    private func contactsRow(in app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any)[Self.contactsRowID]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The Settings Contacts access row should exist.")
        return row
    }

    @MainActor
    func testSettingsContactsDeniedOffersIOSSettings() throws {
        let app = launchDeniedToSettings()
        let row = contactsRow(in: app)

        XCTAssertEqual(row.label, "Contacts access off. Open iOS Settings")
        XCTAssertTrue(app.buttons[Self.contactsRowID].exists, "Denied offers a button to iOS Settings.")
        XCTAssertFalse(row.label.contains("Allow Contacts access"), "Denied must not offer to prompt.")
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)

        // The button must really leave the app for iOS Settings. A button
        // wired to anything else (the prompt, say) would be inert here, and
        // nothing else in the suite would notice.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        app.buttons[Self.contactsRowID].tap()
        XCTAssertTrue(
            settings.wait(for: .runningForeground, timeout: 10),
            "Open iOS Settings should bring the iOS Settings app to the foreground."
        )
        settings.terminate()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Regards should come back to the foreground.")
        XCTAssertTrue(contactsRow(in: app).label.hasPrefix("Contacts access off"))
    }

    @MainActor
    func testSettingsContactsAuthorizedIsStatusOnly() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--regards-first-launch-runtime")
        app.launch()
        app.reachOnboardingStarterStep()
        let skip = app.buttons["starter.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        XCTAssertTrue(overdue.waitForExistence(timeout: 10), "Skipping the starter step should reveal the tabs.")
        navigateToTab(named: "Settings", from: "screen.overdue", to: "screen.settings", in: app)

        let row = contactsRow(in: app)

        XCTAssertTrue(row.label.contains("Contacts access on"))
        XCTAssertFalse(row.label.contains("Open iOS Settings"))
        XCTAssertFalse(app.buttons[Self.contactsRowID].exists, "Authorized is status text, not a control.")
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// With Contacts access off nothing was imported, and the empty picker must
    /// say why and where to fix it. "Regards hasn't imported any contacts yet"
    /// would leave a denied user with no way forward.
    @MainActor
    private func openChoosePeopleWithContactsOff() -> XCUIApplication {
        let app = launchDeniedToSettings()
        navigateFromSettings(triggerIdentifier: "settings.choose-starters", to: "screen.starter-contacts", in: app)
        return app
    }

    @MainActor
    func testSettingsChoosePeopleWithContactsOffExplainsAccessIsOff() {
        let app = openChoosePeopleWithContactsOff()

        let reason = app.staticTexts[
            "Regards can't see your contacts. Go back and turn on Contacts access to choose people."
        ]
        XCTAssertTrue(reason.waitForExistence(timeout: 10), "The empty picker should say Contacts access is off.")
        XCTAssertFalse(
            app.staticTexts["Regards hasn't imported any contacts yet."].exists,
            "The generic empty copy would hide why the list is empty."
        )
    }

    @MainActor
    func testSettingsChoosePeopleWithContactsOffPassesAudit() throws {
        let app = openChoosePeopleWithContactsOff()
        XCTAssertTrue(app.descendants(matching: .any)["starter.empty"].waitForExistence(timeout: 10))

        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testSettingsContactsPassesAuditAtAccessibility5() throws {
        let app = launchDeniedToSettings(dynamicTypeSize: "accessibility5")
        _ = contactsRow(in: app)

        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// Pin: the mock launch has no Contacts source, so a row there would be
    /// inert. This passes on the code before the row existed, on purpose. The
    /// other People row proves the screen did load, so the absence isn't a
    /// screen that failed to render.
    @MainActor
    func testSettingsWithoutContactsSourceHasNoContactsRow() throws {
        let app = launchToSettings()

        XCTAssertTrue(app.descendants(matching: .any)["settings.choose-starters"].exists)
        XCTAssertFalse(app.descendants(matching: .any)[Self.contactsRowID].exists)
        XCTAssertFalse(app.descendants(matching: .any)["\(Self.contactsRowID).error"].exists)
    }
}
