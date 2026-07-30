import XCTest

/// Phase 0 / PR3 accessibility smoke audit. Launches the app, waits past the
/// brief splash for the tab root, and runs Apple's built-in accessibility
/// audit against the Overdue tab (the default landing screen). Per-screen
/// audits live in `ScreensAccessibilityTests`.
final class LaunchAccessibilityTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndOverdueTabPassAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launch()

        // The splash (launch.root) shows for ~600ms before crossfading to the
        // tab root. Wait for the Overdue screen to be on-screen before the
        // audit runs so we're looking at the real post-launch state.
        let overdue = app.descendants(matching: .any)["screen.overdue"]
        XCTAssertTrue(overdue.waitForExistence(timeout: 10),
                      "Overdue tab should appear after the splash.")
        let splash = app.descendants(matching: .any)["launch.root"]
        XCTAssertTrue(splash.waitForNonExistence(timeout: 10),
                      "Splash transition should finish before the audit begins.")

        try app.performAccessibilityAudit(for: ScreensAccessibilityTests.structuralAuditCategories)
    }
}
