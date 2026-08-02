import XCTest

/// Audits each major screen through real tab and push interactions.
/// The merge policy and sensory carve-outs live in
/// `ios/docs/accessibility.md`.
final class ScreensAccessibilityTests: XCTestCase {

    /// Structural checks are the enabled automated audit set. The sensory categories
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
        assertReadOnlyBanner(in: app)
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
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
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

    /// The Contacts stack must preserve Edit Contact across a tab switch,
    /// then support a second Edit push after returning through Back.
    @MainActor
    func testEditContactSurvivesContactsTabRoundTripAndRepeats() {
        let app = launchToContactDetailFromContacts()
        navigate(
            from: "screen.contact-detail",
            to: "screen.edit-contact",
            triggerDescription: "Edit",
            in: app
        ) {
            app.navigationBars.buttons["Edit"]
        }
        assertReadOnlyBanner(in: app)

        navigateToTab(
            named: "Overdue",
            from: "screen.edit-contact",
            to: "screen.overdue",
            in: app
        )
        navigateToTab(
            named: "Contacts",
            from: "screen.overdue",
            to: "screen.edit-contact",
            in: app
        )
        assertReadOnlyBanner(in: app)

        navigate(
            from: "screen.edit-contact",
            to: "screen.contact-detail",
            triggerDescription: "Back",
            in: app
        ) {
            app.navigationBars.buttons.element(boundBy: 0)
        }
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
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
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
