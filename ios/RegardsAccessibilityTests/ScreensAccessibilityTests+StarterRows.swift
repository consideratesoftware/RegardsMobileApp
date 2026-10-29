import XCTest

/// The starter picker's contact rows. A row is one control: the button the
/// user taps. A wrapper element around an inner button reads twice to
/// VoiceOver and gives the audit two elements to describe. The mock launch is
/// enough: its contacts are already tracked, and the row shape does not depend
/// on that.
extension ScreensAccessibilityTests {
    @MainActor
    func testStarterPickerContactRowIsASingleAccessibilityElement() {
        let app = launchToSettings()
        navigateFromSettings(
            triggerIdentifier: "settings.choose-starters",
            to: "screen.starter-contacts",
            in: app
        )
        let rowID = "starter.contact.Leia Organa"
        let row = app.buttons[rowID]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The mock contact should be offered.")

        XCTAssertEqual(row.label, "Leia Organa", "The row's label is the contact name.")
        XCTAssertEqual(
            row.descendants(matching: .button).count, 0,
            "The row must not hold a second button: \(row.debugDescription)"
        )
        XCTAssertEqual(
            app.buttons.matching(identifier: rowID).count, 1,
            "The row id must belong to one element."
        )
    }
}
