import XCTest

/// Audits each major screen through real tab and push interactions.
/// The merge policy and sensory carve-outs live in
/// `ios/docs/accessibility.md`.
final class ScreensAccessibilityTests: XCTestCase {

    /// Structural checks are merge-blocking. The sensory categories
    /// (`contrast`, `hitRegion`, `dynamicType`, `textClipped`) and their
    /// current carve-outs are documented in `ios/docs/accessibility.md`.
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
        navigateToTab(
            named: "Upcoming",
            from: "screen.overdue",
            to: "screen.upcoming",
            in: app
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testContactsTabPassesAudit() throws {
        let app = launchToOverdue()
        navigateToTab(
            named: "Contacts",
            from: "screen.overdue",
            to: "screen.contacts",
            in: app
        )
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
        navigateFromSettings(
            triggerIdentifier: "settings.reminder-windows",
            to: "screen.reminder-windows",
            in: app
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testMergeDuplicatesPassesAudit() throws {
        let app = launchToSettings()
        navigateFromSettings(
            triggerIdentifier: "settings.find-duplicate-contacts",
            to: "screen.merge-duplicates",
            in: app
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testTransparencyPassesAudit() throws {
        let app = launchToSettings()
        navigateFromSettings(
            triggerIdentifier: "settings.transparency",
            to: "screen.transparency",
            in: app
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testOnboardingPassesAudit() throws {
        let app = launchToSettings()
        navigateFromSettings(
            triggerIdentifier: "settings.onboarding-preview",
            to: "screen.onboarding",
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
        navigate(
            from: "screen.contact-detail",
            to: "screen.edit-contact",
            triggerDescription: "Edit",
            in: app
        ) {
            app.navigationBars.buttons["Edit"]
        }
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testEditContactBackReturnsToContactDetail() {
        let app = launchToContactDetailFromContacts()
        assertEditRoundTrip(in: app)
    }

    /// Exercises the stable-ID Contact Detail push from Overdue. The
    /// Contacts test covers the same destination flow from All Contacts.
    @MainActor
    func testContactDetailFromOverduePassesAudit() throws {
        let app = launchToOverdue()
        // Rows are synthetic `.other` elements, so select by identifier.
        navigateToRow(
            identifier: "overdue.row",
            index: 0,
            sourceIdentifier: "screen.overdue",
            in: app
        )
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testContactDetailFromUpcomingPassesAudit() throws {
        let app = launchToOverdue()
        navigateToTab(
            named: "Upcoming",
            from: "screen.overdue",
            to: "screen.upcoming",
            in: app
        )
        navigateToRow(
            identifier: "upcoming.row",
            index: 0,
            sourceIdentifier: "screen.upcoming",
            in: app
        )
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testEditContactBackReturnsToOverdueContactDetail() {
        let app = launchToOverdue()
        navigateToRow(
            identifier: "overdue.row",
            index: 0,
            sourceIdentifier: "screen.overdue",
            in: app
        )
        assertEditRoundTrip(in: app)
    }

    @MainActor
    func testEditContactBackReturnsToUpcomingContactDetail() {
        let app = launchToOverdue()
        navigateToTab(
            named: "Upcoming",
            from: "screen.overdue",
            to: "screen.upcoming",
            in: app
        )
        navigateToRow(
            identifier: "upcoming.row",
            index: 0,
            sourceIdentifier: "screen.upcoming",
            in: app
        )
        assertEditRoundTrip(in: app)
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
        navigateToRow(
            identifier: "overdue.row",
            index: 0,
            sourceIdentifier: "screen.overdue",
            in: app
        )
        let firstDetail = app.descendants(matching: .any)["screen.contact-detail"]
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
        // The hero header text is the only `staticText` child with an
        // `.isHeader` trait on this screen.
        let firstName = firstDetail.staticTexts
            .matching(NSPredicate(format: "traits & %llu != 0", UIAccessibilityTraits.header.rawValue))
            .firstMatch.label
        navigate(
            from: "screen.contact-detail",
            to: "screen.overdue",
            triggerDescription: "Back",
            in: app
        ) {
            app.navigationBars.buttons.element(boundBy: 0)
        }

        // Tap second row → its hero header should differ.
        XCTAssertTrue(overdue.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(rows.count, 1)
        navigateToRow(
            identifier: "overdue.row",
            index: 1,
            sourceIdentifier: "screen.overdue",
            in: app
        )
        let secondDetail = app.descendants(matching: .any)["screen.contact-detail"]
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
        let secondName = secondDetail.staticTexts
            .matching(NSPredicate(format: "traits & %llu != 0", UIAccessibilityTraits.header.rawValue))
            .firstMatch.label

        XCTAssertNotEqual(
            firstName,
            secondName,
            "Contact Detail must rebuild its VM per push so two consecutive taps show different contacts."
        )
    }
}

private extension ScreensAccessibilityTests {
    // MARK: - Helpers

    @MainActor
    private func launchToOverdue() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
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
        navigateToTab(
            named: "Settings",
            from: "screen.overdue",
            to: "screen.settings",
            in: app
        )
        return app
    }

    @MainActor
    private func launchToContactDetailFromContacts() -> XCUIApplication {
        let app = launchToOverdue()
        navigateToTab(
            named: "Contacts",
            from: "screen.overdue",
            to: "screen.contacts",
            in: app
        )
        let contacts = app.descendants(matching: .any)["screen.contacts"]
        let detail = app.descendants(matching: .any)["screen.contact-detail"]

        // Contacts rows currently resolve as buttons rather than the
        // synthetic `.other` elements used by Overdue and Upcoming.
        // Re-resolve once because rapid test relaunches can drop a
        // synthesized row tap before SwiftUI handles it.
        for _ in 0..<2 {
            if detail.exists, !contacts.exists {
                break
            }

            let firstRow = contacts.descendants(matching: .button).firstMatch
            guard firstRow.waitForExistence(timeout: 10) else {
                continue
            }
            tapLiveCoordinate(of: firstRow)
            if detail.waitForExistence(timeout: 10),
               contacts.waitForNonExistence(timeout: 10) {
                break
            }
        }

        XCTAssertTrue(
            detail.exists && !contacts.exists,
            "The first Contacts row should replace Contacts with Contact Detail."
        )
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    private func navigateToTab(
        named name: String,
        from sourceIdentifier: String,
        to screenIdentifier: String,
        in app: XCUIApplication
    ) {
        let source = app.descendants(matching: .any)[sourceIdentifier]
        let destination = app.descendants(matching: .any)[screenIdentifier]
        XCTAssertTrue(
            source.waitForExistence(timeout: 10),
            "\(sourceIdentifier) should exist before selecting the \(name) tab."
        )

        // Rapid simulator relaunches can leave a stale, hittable tab-bar
        // element in the automation hierarchy. Resolve the current button
        // for each attempt and allow two bounded retries when synthesized
        // taps are dropped. The screen waits remain plain queries.
        for _ in 0..<3 {
            if destination.exists, !source.exists {
                return
            }

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
            if destination.waitForExistence(timeout: 10),
               source.waitForNonExistence(timeout: 10) {
                return
            }
        }

        XCTFail("\(name) tab should show \(screenIdentifier).")
    }

    @MainActor
    private func navigateFromSettings(
        triggerIdentifier: String,
        to screenIdentifier: String,
        in app: XCUIApplication
    ) {
        let source = app.descendants(matching: .any)["screen.settings"]
        let destination = app.descendants(matching: .any)[screenIdentifier]
        let trigger = app.descendants(matching: .any)[triggerIdentifier]
        XCTAssertTrue(
            source.waitForExistence(timeout: 10),
            "Settings should exist before opening \(screenIdentifier)."
        )

        for _ in 0..<2 {
            if destination.exists, !source.exists {
                return
            }

            guard trigger.waitForExistence(timeout: 10), trigger.isHittable else {
                continue
            }
            tapLiveCoordinate(of: trigger)
            if destination.waitForExistence(timeout: 10),
               source.waitForNonExistence(timeout: 10) {
                return
            }
        }

        XCTFail("\(triggerIdentifier) should replace Settings with \(screenIdentifier).")
    }

    @MainActor
    private func navigateToRow(
        identifier: String,
        index: Int,
        sourceIdentifier: String,
        in app: XCUIApplication
    ) {
        let source = app.descendants(matching: .any)[sourceIdentifier]
        let detail = app.descendants(matching: .any)["screen.contact-detail"]
        let plainRow = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(
            source.waitForExistence(timeout: 10),
            "\(sourceIdentifier) should exist before opening Contact Detail."
        )

        // Row taps can be dropped by the same rapid-relaunch automation race
        // as tab taps. Wait on the plain identifier query, then re-resolve
        // the indexed row and its live coordinate before each attempt.
        for _ in 0..<2 {
            if detail.exists, !source.exists {
                return
            }

            guard plainRow.waitForExistence(timeout: 10) else {
                continue
            }
            let rows = app.descendants(matching: .any)
                .matching(identifier: identifier)
                .allElementsBoundByIndex
            guard rows.indices.contains(index), rows[index].isHittable else {
                continue
            }
            tapLiveCoordinate(of: rows[index])
            if detail.waitForExistence(timeout: 10),
               source.waitForNonExistence(timeout: 10) {
                return
            }
        }

        XCTFail("\(identifier) row \(index) should open Contact Detail.")
    }

    @MainActor
    private func navigate(
        from sourceIdentifier: String,
        to destinationIdentifier: String,
        triggerDescription: String,
        in app: XCUIApplication,
        trigger: () -> XCUIElement
    ) {
        let source = app.descendants(matching: .any)[sourceIdentifier]
        let destination = app.descendants(matching: .any)[destinationIdentifier]
        XCTAssertTrue(
            source.waitForExistence(timeout: 10),
            "\(sourceIdentifier) should exist before activating \(triggerDescription)."
        )

        for _ in 0..<2 {
            if destination.exists, !source.exists {
                return
            }

            let liveTrigger = trigger()
            guard liveTrigger.waitForExistence(timeout: 10), liveTrigger.isHittable else {
                continue
            }
            tapLiveCoordinate(of: liveTrigger)
            if destination.waitForExistence(timeout: 10),
               source.waitForNonExistence(timeout: 10) {
                return
            }
        }

        XCTFail("\(triggerDescription) should show \(destinationIdentifier).")
    }

    @MainActor
    private func assertEditRoundTrip(in app: XCUIApplication) {
        navigate(
            from: "screen.contact-detail",
            to: "screen.edit-contact",
            triggerDescription: "Edit",
            in: app
        ) {
            app.navigationBars.buttons["Edit"]
        }
        navigate(
            from: "screen.edit-contact",
            to: "screen.contact-detail",
            triggerDescription: "Back",
            in: app
        ) {
            app.navigationBars.buttons.element(boundBy: 0)
        }
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 20))
    }

    @MainActor
    private func tapLiveCoordinate(of element: XCUIElement) {
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
    }
}
