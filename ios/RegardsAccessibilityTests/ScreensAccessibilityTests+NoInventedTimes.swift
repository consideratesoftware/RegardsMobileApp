import XCTest

/// Screens must not show times the app never computed. Three placeholders were
/// removed: Overdue's "next digest at 6:00 pm" and "Quiet until 6:00 pm", and
/// Contact Detail's "Next reminder: Today, 6:30 pm". These assert the texts
/// stay gone.
extension ScreensAccessibilityTests {

    @MainActor
    private func labels(containing text: String, in app: XCUIApplication) -> Int {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).count
    }

    @MainActor
    func testOverdueShowsNoInventedTimes() throws {
        let app = launchToOverdue()

        XCTAssertEqual(labels(containing: "next digest at", in: app), 0)
        XCTAssertEqual(labels(containing: "Quiet until", in: app), 0)
        XCTAssertEqual(labels(containing: "6:00 pm", in: app), 0)
    }

    @MainActor
    func testContactDetailShowsNoInventedNextReminder() throws {
        let app = launchToContactDetailFromContacts()

        XCTAssertEqual(labels(containing: "Next reminder", in: app), 0)
        XCTAssertEqual(labels(containing: "6:30 pm", in: app), 0)
    }
}
