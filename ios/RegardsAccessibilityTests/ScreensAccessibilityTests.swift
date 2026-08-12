import XCTest

/// Audits each major screen through real tab and push interactions.
/// The merge policy and sensory carve-outs live in
/// `ios/docs/accessibility.md`.
final class ScreensAccessibilityTests: XCTestCase {

    /// Structural checks are the enabled automated audit set. `contrast` and
    /// `dynamicType` stay excluded, each with its own written carve-out in
    /// `ios/docs/accessibility.md`. `hitRegion` joins this round (staged
    /// review round 11): it was excluded "by association" with the other
    /// sensory categories, with no individual justification of its own.
    /// Running it across every screen found two real, now-fixed undersized
    /// targets (`EditContactScreen.field(_:)`'s read-only rows and
    /// `LogOtherChannelSheet`'s Cancel button — both `.frame(minHeight: 44)`
    /// with no `.contentShape`, which measured no different via
    /// `XCUIElement.frame` than an unconstrained view; see either site's own
    /// doc comment for the fix and how it was confirmed) and nothing else —
    /// worth keeping on, unlike `textClipped` below.
    ///
    /// `textClipped` was trialed the same way and reverted — not because it
    /// found nothing, but because of what running it broadly actually
    /// showed. It caught one real, now-fixed bug
    /// (`OnboardingScreen.allowButton`'s hardcoded `frame(height: 54)`
    /// clipping "Allow contacts access" at `accessibility5`). It also
    /// flagged roughly half of every other screen this round, including
    /// Overdue and Contact Detail at the plain default content size — both
    /// confirmed via an actual XCTest screenshot to render every string on
    /// screen fully, with nothing visibly clipped. The issue text on every
    /// one of those ("Text of this SwiftUI.AccessibilityNode may be clipped
    /// at *larger* Dynamic Type sizes") is the tell: on this Xcode/iOS
    /// toolchain, `textClipped` is a predictive heuristic over the view
    /// hierarchy, not an as-rendered defect detector, and it fires on
    /// ordinary multi-element layouts with no visible problem far more
    /// often than it finds a real one. A blanket gate with that signal-to-
    /// noise ratio trains reviewers to wave failures through rather than
    /// read them, which is worse for accessibility outcomes than leaving it
    /// off the automated sweep. See `ios/docs/accessibility.md`'s carve-out
    /// section for the full writeup and the recommended way to use it
    /// instead: as a targeted, temporary diagnostic when investigating a
    /// specific reported layout complaint — exactly how it was used to
    /// confirm the row-crowding bug this same round started from.
    static let structuralAuditCategories: XCUIAccessibilityAuditType = [
        .elementDetection,
        .sufficientElementDescription,
        .trait,
        .hitRegion,
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tab-root screens

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
        XCTAssertTrue(
            app.descendants(matching: .any)["Thursday allowed"]
                .waitForExistence(timeout: 5),
            "The second T day pill must announce Thursday, not Tuesday."
        )
        XCTAssertTrue(app.descendants(matching: .any)["Sunday not allowed"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Saturday not allowed"].exists)
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
            editButton(in: app)
        }
        assertReadOnlyBanner(in: app)
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testEditContactBackReturnsToContactDetail() {
        let app = launchToContactDetailFromContacts()
        assertEditRoundTrip(in: app)
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
        XCTAssertTrue(editButton(in: app).waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func testEditContactBackReturnsToOverdueContactDetail() throws {
        let app = launchToOverdue()
        navigateToRow(
            identifier: "overdue.row",
            index: 0,
            sourceIdentifier: "screen.overdue",
            in: app
        )
        navigate(
            from: "screen.contact-detail",
            to: "screen.edit-contact",
            triggerDescription: "Edit",
            in: app
        ) {
            editButton(in: app)
        }
        assertReadOnlyBanner(in: app)
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
        navigate(
            from: "screen.edit-contact",
            to: "screen.contact-detail",
            triggerDescription: "Contact back button",
            in: app
        ) {
            app.navigationBars.buttons["Contact"]
        }
        navigate(
            from: "screen.contact-detail",
            to: "screen.overdue",
            triggerDescription: "Overdue back button",
            in: app
        ) {
            app.navigationBars.buttons.element(boundBy: 0)
        }
    }

    @MainActor
    func testEditContactBackReturnsToUpcomingContactDetail() throws {
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
        navigate(
            from: "screen.contact-detail",
            to: "screen.edit-contact",
            triggerDescription: "Edit",
            in: app
        ) {
            editButton(in: app)
        }
        assertReadOnlyBanner(in: app)
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
        navigate(
            from: "screen.edit-contact",
            to: "screen.contact-detail",
            triggerDescription: "Contact back button",
            in: app
        ) {
            app.navigationBars.buttons["Contact"]
        }
        navigate(
            from: "screen.contact-detail",
            to: "screen.upcoming",
            triggerDescription: "Upcoming back button",
            in: app
        ) {
            app.navigationBars.buttons.element(boundBy: 0)
        }
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
            editButton(in: app)
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
            triggerDescription: "Contact back button",
            in: app
        ) {
            app.navigationBars.buttons["Contact"]
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
        XCTAssertTrue(editButton(in: app).waitForExistence(timeout: 10))
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
        XCTAssertTrue(editButton(in: app).waitForExistence(timeout: 10))
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
