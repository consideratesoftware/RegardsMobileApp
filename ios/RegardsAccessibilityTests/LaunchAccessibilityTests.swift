import XCTest

/// Launch accessibility smoke audits. The mock runtime opens the tab root
/// immediately; production-state fixtures cover onboarding and recoverable
/// launch paths. Per-screen audits live in `ScreensAccessibilityTests`.
final class LaunchAccessibilityTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndOverdueTabPassAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--regards-mock-runtime")
        app.launch()

        // The deterministic mock runtime starts ready and should render the
        // tab root without exposing the production loading splash.
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        XCTAssertTrue(overdue.waitForExistence(timeout: 10),
                      "The ready mock runtime should open the Overdue tab immediately.")
        let splash = app.descendants(matching: .any)["launch.root"]
        XCTAssertTrue(splash.waitForNonExistence(timeout: 10),
                      "Mock launch should not expose the production loading splash.")

        try app.performAccessibilityAudit(for: ScreensAccessibilityTests.structuralAuditCategories)
    }

    @MainActor
    func testProductionOpenFailurePassesAuditAndRetryRecovers() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--regards-launch-fails-once")
        app.launchEnvironment["REGARDS_UI_TEST_DYNAMIC_TYPE"] = "accessibility5"
        app.launch()

        let failure = app.descendants(matching: .any)["launch.failure"]
        XCTAssertTrue(
            failure.waitForExistence(timeout: 10),
            "A production-open failure should reveal a recoverable error screen."
        )
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: ScreensAccessibilityTests.structuralAuditCategories)

        retry.tap()
        let onboarding = app.descendants(matching: .any)["screen.onboarding"]
        XCTAssertTrue(
            onboarding.waitForExistence(timeout: 10),
            "Retry should reopen the runtime and resume first launch."
        )
    }

    @MainActor
    func testReadyWithoutRuntimePassesAuditAndRetryRecovers() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--regards-ready-without-runtime")
        app.launchEnvironment["REGARDS_UI_TEST_DYNAMIC_TYPE"] = "accessibility5"
        app.launch()

        let failure = app.descendants(matching: .any)["launch.failure"]
        XCTAssertTrue(
            failure.waitForExistence(timeout: 10),
            "A defensive ready-without-runtime state should reveal launch recovery."
        )
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: ScreensAccessibilityTests.structuralAuditCategories)

        retry.tap()
        let onboarding = app.descendants(matching: .any)["screen.onboarding"]
        XCTAssertTrue(
            onboarding.waitForExistence(timeout: 10),
            "Retry should create the production runtime and resume first launch."
        )
    }

    @MainActor
    func testFirstLaunchImportsContactsAndReachesProductionTabs() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--regards-first-launch-runtime")
        app.launchEnvironment["REGARDS_UI_TEST_DYNAMIC_TYPE"] = "accessibility5"
        app.launch()

        let onboarding = app.descendants(matching: .any)["screen.onboarding"]
        XCTAssertTrue(
            onboarding.waitForExistence(timeout: 10),
            "A fresh production runtime should stop at the Contacts pre-prompt."
        )
        try app.performAccessibilityAudit(for: ScreensAccessibilityTests.structuralAuditCategories)

        let allow = app.buttons["onboarding.allow-contacts"]
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        tap(
            allow,
            until: overdue,
            message: "A completed import should reveal the production-backed tabs."
        )
        let contacts = app.descendants(matching: .any)["screen.contacts"]
        selectTab(named: "Contacts", destination: contacts, in: app)
        XCTAssertTrue(
            app.staticTexts["Leia Organa"].waitForExistence(timeout: 10),
            "Imported, untracked contacts should remain visible in All Contacts."
        )
    }

    @MainActor
    func testFirstLaunchPermissionDenialPassesAuditAndCanBrowse() throws {
        let app = firstLaunchApp(contactsOutcome: "denied")
        app.launch()

        let onboarding = app.descendants(matching: .any)["screen.onboarding"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10))
        let allow = app.buttons["onboarding.allow-contacts"]
        let status = app.staticTexts["onboarding.status"]
        tap(allow, until: status, message: "Permission denial should reveal recovery copy.")
        let browse = app.buttons["onboarding.continue-without-contacts"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(browse.frame.height, 44)
        let why = app.buttons["onboarding.why-we-ask"]
        XCTAssertTrue(why.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(why.frame.height, 44)
        try app.performAccessibilityAudit(for: ScreensAccessibilityTests.structuralAuditCategories)

        browse.tap()
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        XCTAssertTrue(
            overdue.waitForExistence(timeout: 10),
            "Browse-only onboarding should reveal production-backed tabs."
        )
    }

    @MainActor
    func testPreviouslyDeniedPermissionPassesAuditOnFirstRender() throws {
        let app = firstLaunchApp(contactsOutcome: "denied-at-launch")
        app.launch()

        let onboarding = app.descendants(matching: .any)["screen.onboarding"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10))
        let status = app.staticTexts["onboarding.status"]
        XCTAssertTrue(
            status.waitForExistence(timeout: 5),
            "A persisted denial should expose recovery on the first onboarding render."
        )
        let browse = app.buttons["onboarding.continue-without-contacts"]
        XCTAssertTrue(browse.waitForExistence(timeout: 5))
        XCTAssertTrue(browse.isEnabled)
        try app.performAccessibilityAudit(for: ScreensAccessibilityTests.structuralAuditCategories)
    }

    @MainActor
    func testFirstLaunchImportFailurePassesAuditAndRetryCompletes() throws {
        let app = firstLaunchApp(contactsOutcome: "import-fails-once")
        app.launch()

        let onboarding = app.descendants(matching: .any)["screen.onboarding"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10))
        let allow = app.buttons["onboarding.allow-contacts"]
        let status = app.staticTexts["onboarding.status"]
        tap(allow, until: status, message: "Import failure should reveal retry copy.")
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: allow
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enabled], timeout: 5),
            .completed,
            "Retry should become enabled after the failed import finishes."
        )
        try app.performAccessibilityAudit(for: ScreensAccessibilityTests.structuralAuditCategories)

        allow.tap()
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        XCTAssertTrue(
            overdue.waitForExistence(timeout: 10),
            "Retry should resume the import and reveal production-backed tabs."
        )
    }

    @MainActor
    func testFirstLaunchImportFailureCanBrowseWithoutContacts() throws {
        let app = firstLaunchApp(contactsOutcome: "import-fails-once")
        app.launch()

        let onboarding = app.descendants(matching: .any)["screen.onboarding"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 10))
        let allow = app.buttons["onboarding.allow-contacts"]
        let status = app.staticTexts["onboarding.status"]
        tap(allow, until: status, message: "Import failure should reveal recovery copy.")
        let browse = app.buttons["onboarding.continue-without-contacts"]
        XCTAssertTrue(
            browse.waitForExistence(timeout: 5),
            "A persistent import failure must offer a browse-only escape."
        )
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: browse
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [enabled], timeout: 5),
            .completed,
            "Browse-only recovery should enable after the failed import finishes."
        )
        try app.performAccessibilityAudit(for: ScreensAccessibilityTests.structuralAuditCategories)

        browse.tap()
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        XCTAssertTrue(
            overdue.waitForExistence(timeout: 10),
            "Browse-only recovery should reveal production-backed tabs."
        )
    }

    @MainActor
    private func firstLaunchApp(contactsOutcome: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--regards-first-launch-runtime")
        app.launchEnvironment["REGARDS_UI_TEST_DYNAMIC_TYPE"] = "accessibility5"
        app.launchEnvironment["REGARDS_UI_TEST_CONTACTS_OUTCOME"] = contactsOutcome
        return app
    }

    @MainActor
    private func tap(
        _ button: XCUIElement,
        until destination: XCUIElement,
        message: String
    ) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        if !destination.waitForExistence(timeout: 5) {
            // At accessibility5 XCTest must auto-scroll this CTA. The first
            // synthesized tap can finish that scroll without delivering the
            // action, so retry once against the now-visible plain element.
            XCTAssertTrue(button.exists)
            button.tap()
        }
        XCTAssertTrue(destination.waitForExistence(timeout: 5), message)
    }

    @MainActor
    private func selectTab(
        named name: String,
        destination: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<3 {
            if destination.exists { return }
            let button = app.tabBars.buttons[name]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap()
            if destination.waitForExistence(timeout: 5) { return }
        }
        XCTFail("\(name) tab should show its root screen.")
    }
}
