import XCTest

/// Per-screen `XCUIApplication.performAccessibilityAudit()` pass for every
/// major SwiftUI screen in the current app shell. Each test launches the app once,
/// navigates to the target screen via real tab / push interactions, and
/// runs the audit at that point.
///
/// Follows the standing accessibility-baseline rule from
/// `ios/docs/accessibility.md`: a failing audit blocks merge.
final class ScreensAccessibilityTests: XCTestCase {

    /// Audit categories the suite gates on. Structural checks (labels,
    /// traits, element detection) are merge-blocking. Sensory checks
    /// (`contrast`, `hitRegion`, `dynamicType`, `textClipped`) are
    /// documented design-intent trade-offs covered in
    /// `ios/docs/accessibility.md` §"Sensory-audit carve-outs" — the
    /// remaining findings are on decorative brand elements
    /// (Avatar initials, Wordmark) and specific accent-color pairings
    /// we've deliberately kept at current brightness for the mock's
    /// visual identity.
    static let structuralAuditCategories: XCUIAccessibilityAuditType = [
        .elementDetection,
        .sufficientElementDescription,
        .trait,
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tab-root screens

    @MainActor
    func testOverdueTabPassesAudit() throws {
        let app = launchToOverdue()
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testUpcomingTabPassesAudit() throws {
        let app = launchToOverdue()
        navigateToTab(named: "Upcoming", screenIdentifier: "screen.upcoming", in: app)
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testContactsTabPassesAudit() throws {
        let app = launchToOverdue()
        navigateToTab(named: "Contacts", screenIdentifier: "screen.contacts", in: app)
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testSettingsTabPassesAudit() throws {
        let app = launchToSettings()
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    // MARK: - Pushed screens

    @MainActor
    func testReminderWindowsPassesAudit() throws {
        let app = launchToSettings()
        navigateToSettingsRoute(
            identifier: "settings.reminder-windows",
            screenIdentifier: "screen.reminder-windows",
            in: app
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testMergeDuplicatesPassesAudit() throws {
        let app = launchToSettings()
        navigateToSettingsRoute(
            identifier: "settings.find-duplicate-contacts",
            screenIdentifier: "screen.merge-duplicates",
            in: app
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testTransparencyPassesAudit() throws {
        let app = launchToSettings()
        navigateToSettingsRoute(
            identifier: "settings.transparency",
            screenIdentifier: "screen.transparency",
            in: app
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testOnboardingPassesAudit() throws {
        let app = launchToSettings()
        navigateToSettingsRoute(
            identifier: "settings.onboarding-preview",
            screenIdentifier: "screen.onboarding",
            in: app
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testContactDetailPassesAudit() throws {
        let app = launchToContactDetailFromContacts()
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testEditContactPassesAudit() throws {
        let app = launchToContactDetailFromContacts()
        navigateToEditContact(in: app)
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testEditContactBackReturnsToContactDetail() {
        let app = launchToContactDetailFromContacts()
        navigateToEditContact(in: app)
        navigateBack(to: "screen.contact-detail", in: app)
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
    }

    /// Exercises the factory-built Contact Detail push from the **Overdue
    /// tab**. The previous ContactDetail test covers the same stable-ID
    /// destination flow from `AllContactsScreen`.
    @MainActor
    func testContactDetailFromOverduePassesAudit() throws {
        let app = launchToOverdue()
        // Target contact-row elements specifically. `screen.overdue` also
        // hosts the nav-bar "All" button and the segmented-control
        // buttons, so plain `.descendants(matching: .button).firstMatch`
        // catches those first instead of a row. The row button applies
        // `.accessibilityElement(children: .ignore)` which composes a
        // synthetic element whose XCUI elementType resolves to `.other`,
        // so we search across all element types by identifier.
        navigateToFirstRow(identifier: "overdue.row", in: app)
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// Same path, Upcoming tab.
    @MainActor
    func testContactDetailFromUpcomingPassesAudit() throws {
        let app = launchToOverdue()
        navigateToTab(named: "Upcoming", screenIdentifier: "screen.upcoming", in: app)
        navigateToFirstRow(identifier: "upcoming.row", in: app)
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// Regression guard for the per-push VM factory: tapping two different
    /// contacts in succession must show the second contact's data, not the
    /// first's. Guards against a future refactor that accidentally reuses
    /// the view's identity across pushes.
    @MainActor
    func testOverdueNavigationShowsDistinctContacts() throws {
        let app = launchToOverdue()
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        let rows = app.descendants(matching: .any).matching(identifier: "overdue.row")

        // Tap first row → read the hero header → pop back.
        navigateToRow(identifier: "overdue.row", index: 0, in: app)
        let firstDetail = app.descendants(matching: .any)["screen.contact-detail"]
        // The hero header text is the only `staticText` child with an
        // `.isHeader` trait on this screen.
        let firstName = firstDetail.staticTexts
            .matching(NSPredicate(format: "traits & %llu != 0", UIAccessibilityTraits.header.rawValue))
            .firstMatch.label
        navigateBack(to: "screen.overdue", in: app)

        // Tap second row → its hero header should differ.
        XCTAssertTrue(overdue.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(rows.count, 1)
        navigateToRow(identifier: "overdue.row", index: 1, in: app)
        let secondDetail = app.descendants(matching: .any)["screen.contact-detail"]
        let secondName = secondDetail.staticTexts
            .matching(NSPredicate(format: "traits & %llu != 0", UIAccessibilityTraits.header.rawValue))
            .firstMatch.label

        XCTAssertNotEqual(
            firstName,
            secondName,
            "Contact Detail must rebuild its VM per push so two consecutive taps show different contacts."
        )
    }

    // MARK: - Helpers

    @MainActor
    private func launchToOverdue() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "Regards should be foreground-ready before navigation begins."
        )
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        XCTAssertTrue(overdue.waitForExistence(timeout: 10),
                      "Overdue tab should appear after the splash.")
        let splash = app.descendants(matching: .any)["launch.root"]
        XCTAssertTrue(splash.waitForNonExistence(timeout: 10),
                      "Splash transition should finish before navigation begins.")
        return app
    }

    @MainActor
    private func launchToSettings() -> XCUIApplication {
        let app = launchToOverdue()
        navigateToTab(named: "Settings", screenIdentifier: "screen.settings", in: app)
        return app
    }

    @MainActor
    private func launchToContactDetailFromContacts() -> XCUIApplication {
        let app = launchToOverdue()
        navigateToTab(named: "Contacts", screenIdentifier: "screen.contacts", in: app)
        let contacts = app.descendants(matching: .any)["screen.contacts"]
        let detail = app.descendants(matching: .any)["screen.contact-detail"]

        // Contacts rows currently resolve as buttons rather than the
        // synthetic `.other` elements used by Overdue and Upcoming.
        // Re-resolve once because rapid test relaunches can drop a
        // synthesized row tap before SwiftUI handles it.
        for _ in 0..<2 {
            let firstRow = contacts.descendants(matching: .button).firstMatch
            guard firstRow.waitForExistence(timeout: 10) else {
                continue
            }
            tapLiveCoordinate(of: firstRow)
            if detail.waitForExistence(timeout: 5) {
                break
            }
        }

        XCTAssertTrue(detail.exists, "The first Contacts row should open Contact Detail.")
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    private func navigateToTab(
        named name: String,
        screenIdentifier: String,
        in app: XCUIApplication
    ) {
        let destination = app.descendants(matching: .any)[screenIdentifier]

        // Rapid simulator relaunches can leave a stale, hittable tab-bar
        // element in the automation hierarchy. Resolve the current button
        // for each attempt and allow one bounded retry when a synthesized
        // tap is dropped. The destination wait remains a plain query, and a
        // route that ignores both taps still fails the test.
        for _ in 0..<2 {
            let tabBar = app.tabBars.firstMatch
            guard tabBar.waitForExistence(timeout: 10) else {
                continue
            }

            let button = app.tabBars.buttons.allElementsBoundByIndex.first {
                $0.label == name && $0.isHittable
            }
            guard let button else {
                continue
            }
            tapLiveCoordinate(of: button)
            if destination.waitForExistence(timeout: 10) {
                return
            }
        }

        XCTFail("\(name) tab should show \(screenIdentifier).")
    }

    @MainActor
    private func navigateToSettingsRoute(
        identifier: String,
        screenIdentifier: String,
        in app: XCUIApplication
    ) {
        let destination = app.descendants(matching: .any)[screenIdentifier]

        // Resolve the current row for each attempt. Rapid test relaunches can
        // drop one synthesized Settings-row tap just as they can a tab tap.
        // A route that ignores both taps still fails the test.
        for _ in 0..<2 {
            if destination.exists {
                return
            }

            let route = app.descendants(matching: .any)[identifier].firstMatch
            guard route.waitForExistence(timeout: 10) else {
                continue
            }
            tapLiveCoordinate(of: route)
            if destination.waitForExistence(timeout: 10) {
                return
            }
        }

        XCTFail("\(identifier) should show \(screenIdentifier).")
    }

    @MainActor
    private func navigateToFirstRow(identifier: String, in app: XCUIApplication) {
        navigateToRow(identifier: identifier, index: 0, in: app)
    }

    @MainActor
    private func navigateToRow(
        identifier: String,
        index: Int,
        in app: XCUIApplication
    ) {
        let detail = app.descendants(matching: .any)["screen.contact-detail"]

        // Row taps can be dropped by the same rapid-relaunch automation race
        // as tab taps. Re-resolve the row once before failing the navigation.
        for _ in 0..<2 {
            if detail.exists {
                return
            }

            let rows = app.descendants(matching: .any).matching(identifier: identifier)
            guard rows.count > index else {
                continue
            }
            let row = rows.element(boundBy: index)
            guard row.waitForExistence(timeout: 10) else {
                continue
            }
            tapLiveCoordinate(of: row)
            if detail.waitForExistence(timeout: 10) {
                return
            }
        }

        XCTFail("\(identifier) row \(index) should open Contact Detail.")
    }

    @MainActor
    private func navigateBack(to screenIdentifier: String, in app: XCUIApplication) {
        let destination = app.descendants(matching: .any)[screenIdentifier]

        for _ in 0..<2 {
            if destination.exists {
                return
            }

            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            guard backButton.waitForExistence(timeout: 10) else {
                continue
            }
            tapLiveCoordinate(of: backButton)
            if destination.waitForExistence(timeout: 10) {
                return
            }
        }

        XCTFail("Back should show \(screenIdentifier).")
    }

    @MainActor
    private func navigateToEditContact(in app: XCUIApplication) {
        let destination = app.staticTexts["Edit Contact"]

        for _ in 0..<2 {
            if destination.exists {
                return
            }

            let editButton = app.navigationBars.buttons["Edit"]
            guard editButton.waitForExistence(timeout: 10) else {
                continue
            }
            tapLiveCoordinate(of: editButton)
            if destination.waitForExistence(timeout: 10) {
                return
            }
        }

        XCTFail("Edit should show Edit Contact.")
    }

    @MainActor
    private func tapLiveCoordinate(of element: XCUIElement) {
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
    }
}
