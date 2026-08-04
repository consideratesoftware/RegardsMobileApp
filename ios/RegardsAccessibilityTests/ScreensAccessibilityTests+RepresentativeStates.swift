import XCTest

extension ScreensAccessibilityTests {
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
        XCTAssertTrue(editButton(in: app).waitForExistence(timeout: 10))
        assertRepresentativeInteractionState(in: app)
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    @MainActor
    func assertRepresentativeMergedState(in rows: XCUIElementQuery) {
        XCTAssertTrue(
            rows.allElementsBoundByIndex.contains {
                $0.label.localizedCaseInsensitiveContains("merged contact")
            },
            "The representative virtual-merge state must remain reachable and announced."
        )
    }

    @MainActor
    func assertRepresentativeOccasionStates(in rows: XCUIElementQuery) {
        let labels = rows.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(
            labels.contains(where: { $0.localizedCaseInsensitiveContains("birthday") }),
            "The representative birthday state must remain reachable and announced."
        )
        XCTAssertTrue(
            labels.contains(where: { $0.localizedCaseInsensitiveContains("anniversary") }),
            "The representative anniversary state must remain reachable and announced."
        )
    }

    @MainActor
    func assertRepresentativeInteractionState(in app: XCUIApplication) {
        XCTAssertTrue(
            app.staticTexts["WhatsApp · reminder caught up"].waitForExistence(timeout: 5),
            "The representative interaction history must remain reachable on Contact Detail."
        )
    }
}
