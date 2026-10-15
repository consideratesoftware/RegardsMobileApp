import XCTest

/// The Settings notifications row in each permission state (§10 item 7). The
/// mock launch never uses the real notification center: it uses
/// `DebugNotificationScheduling`, with its status set from
/// `REGARDS_UI_TEST_NOTIFICATION_STATUS` (or no seam at all for `unavailable`),
/// so no system permission alert can cover an audit. Each test also pins what must not be there: a decided
/// state has no "Turn on" control, and the authorized state has no button at
/// all.
extension ScreensAccessibilityTests {
    private static let notificationsRowID = "settings.notifications"

    @MainActor
    private func notificationsRow(in app: XCUIApplication) -> XCUIElement {
        let row = app.descendants(matching: .any)[Self.notificationsRowID]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The Settings notifications row should exist.")
        return row
    }

    @MainActor
    private func assertRowIsButton(_ isButton: Bool, in app: XCUIApplication, _ message: String) {
        XCTAssertEqual(app.buttons[Self.notificationsRowID].exists, isButton, message)
    }

    @MainActor
    func testSettingsNotificationsNotDeterminedPassesAudit() throws {
        let app = launchToSettings(notificationStatus: "notDetermined")
        let row = notificationsRow(in: app)
        XCTAssertTrue(row.label.contains("Turn on notifications"))
        assertRowIsButton(true, in: app, "Not determined offers a button.")
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)

        // The fake grants the request, so no system alert appears.
        app.buttons[Self.notificationsRowID].tap()

        // The row swaps in place after the grant. Wait for the button to be
        // gone before reading the label, so the old row can't be read.
        XCTAssertTrue(
            app.buttons[Self.notificationsRowID].waitForNonExistence(timeout: 10),
            "The Turn on notifications button should be replaced after the grant."
        )
        let on = notificationsRow(in: app)
        XCTAssertTrue(on.label.contains("Notifications on"), "The row should read Notifications on.")
        XCTAssertFalse(on.label.contains("Turn on notifications"), "The prompt copy should be gone.")
        assertRowIsButton(false, in: app, "Authorized after a grant has no button trait.")
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testSettingsNotificationsDeniedOffersIOSSettings() throws {
        let app = launchToSettings(notificationStatus: "denied")
        let row = notificationsRow(in: app)

        XCTAssertEqual(row.label, "Notifications off. Open iOS Settings")
        assertRowIsButton(true, in: app, "Denied offers a button to iOS Settings.")
        XCTAssertFalse(row.label.contains("Turn on notifications"), "Denied must not offer to prompt.")
        // XCUITest cannot read an accessibility hint, so the audit's
        // description check is the only coverage of it.
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)

        // The button must really leave the app for iOS Settings. A button
        // wired to anything else (the prompt, say) would be inert here, and
        // nothing else in the suite would notice.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        app.buttons[Self.notificationsRowID].tap()
        XCTAssertTrue(
            settings.wait(for: .runningForeground, timeout: 10),
            "Open iOS Settings should bring the iOS Settings app to the foreground."
        )
        settings.terminate()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Regards should come back to the foreground.")
        XCTAssertTrue(notificationsRow(in: app).label.hasPrefix("Notifications off"))
    }

    @MainActor
    func testSettingsNotificationsAuthorizedIsStatusOnly() throws {
        let app = launchToSettings(notificationStatus: "authorized")
        let row = notificationsRow(in: app)

        XCTAssertTrue(row.label.contains("Notifications on"))
        XCTAssertFalse(row.label.contains("Turn on notifications"))
        assertRowIsButton(false, in: app, "Authorized is status text, not a control.")
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testSettingsNotificationsPassesAuditAtAccessibility5() throws {
        let app = launchToSettings(dynamicTypeSize: "accessibility5", notificationStatus: "denied")
        _ = notificationsRow(in: app)

        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// A launch with no notification seam has nothing to show, and a row that
    /// did nothing would be inert. The other Settings rows prove the screen
    /// itself did load, so the absence isn't a screen that failed to render.
    @MainActor
    func testSettingsWithoutNotificationSeamHasNoNotificationsRow() throws {
        let app = launchToSettings(notificationStatus: "unavailable")

        XCTAssertTrue(app.descendants(matching: .any)["settings.reminder-windows"].exists)
        XCTAssertFalse(app.descendants(matching: .any)[Self.notificationsRowID].exists)
        XCTAssertFalse(app.descendants(matching: .any)["\(Self.notificationsRowID).error"].exists)
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    // MARK: Request failure

    /// The UI test target can't import the app module, so this repeats
    /// `NotificationPermissionViewModel.requestFailedMessage`.
    private static let requestFailedMessage = "Couldn't ask for notification permission. Try again."

    /// Taps "Turn on notifications" with a request that throws and returns once
    /// the error line shows. The row must stay a button so the user can retry.
    @MainActor
    private func showRequestFailure(dynamicTypeSize: String?) -> XCUIApplication {
        let app = launchToSettings(
            dynamicTypeSize: dynamicTypeSize,
            notificationStatus: "notDetermined",
            notificationRequestOutcome: "fail"
        )
        XCTAssertTrue(notificationsRow(in: app).label.contains("Turn on notifications"))
        XCTAssertFalse(app.descendants(matching: .any)[Self.notificationsErrorID].exists, "No error before a tap.")

        app.buttons[Self.notificationsRowID].tap()

        let error = app.descendants(matching: .any)[Self.notificationsErrorID]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "A failed request should show an error line.")
        XCTAssertEqual(error.label, Self.requestFailedMessage)
        assertRowIsButton(true, in: app, "A failed request leaves the row retryable.")
        return app
    }

    private static let notificationsErrorID = "settings.notifications.error"

    @MainActor
    func testSettingsNotificationRequestFailureShowsErrorLine() throws {
        let app = showRequestFailure(dynamicTypeSize: nil)

        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testSettingsNotificationRequestFailurePassesAuditAtAccessibility5() throws {
        let app = showRequestFailure(dynamicTypeSize: "accessibility5")

        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }
}
