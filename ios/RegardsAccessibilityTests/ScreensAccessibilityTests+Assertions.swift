import XCTest

/// Generic, screen-agnostic assertion/lookup helpers — split out of
/// `ScreensAccessibilityTests+Navigation.swift` purely to keep that file
/// under the linter's line-length limit as it grew. No behavior change.
extension ScreensAccessibilityTests {
    @MainActor
    func assertStacked(
        _ lower: XCUIElement,
        below upper: XCUIElement,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(
            upper.frame.width,
            0,
            "Upper element: \(message)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            upper.frame.height,
            0,
            "Upper element: \(message)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            lower.frame.width,
            0,
            "Lower element: \(message)",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            lower.frame.height,
            0,
            "Lower element: \(message)",
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            lower.frame.minY,
            upper.frame.maxY,
            message,
            file: file,
            line: line
        )
    }

    @MainActor
    func editButton(in app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons["contact-detail.edit"]
    }
}
