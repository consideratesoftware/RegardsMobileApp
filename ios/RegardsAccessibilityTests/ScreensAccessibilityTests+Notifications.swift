import XCTest

/// The Settings notifications row in each permission state (§10 item 7). The
/// mock launch always uses `DebugNotificationScheduling`, with its status set
/// from `REGARDS_UI_TEST_NOTIFICATION_STATUS`, so no system permission alert
/// can cover an audit. Each test also pins what must not be there: a decided
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

        XCTAssertTrue(row.label.contains("Open iOS Settings"))
        assertRowIsButton(true, in: app, "Denied offers a button to iOS Settings.")
        XCTAssertFalse(row.label.contains("Turn on notifications"), "Denied must not offer to prompt.")
        // XCUITest cannot read an accessibility hint, so the audit's
        // description check is the only coverage of it. Not tapped: that
        // would leave the app.
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
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
}
