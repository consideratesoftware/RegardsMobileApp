import XCTest

extension ScreensAccessibilityTests {
    @MainActor
    func testOverdueTabPassesAudit() throws {
        let app = launchToOverdue()
        let plainRow = app.descendants(matching: .any)["overdue.row"]
        XCTAssertTrue(plainRow.waitForExistence(timeout: 10))
        let rows = app.descendants(matching: .any).matching(identifier: "overdue.row")
        let mergedLabel = rows.allElementsBoundByIndex.first {
            $0.label.localizedCaseInsensitiveContains("merged contact")
        }?.label
        XCTAssertNotNil(
            mergedLabel,
            "The representative virtual-merge state must remain reachable and announced."
        )
        XCTAssertTrue(mergedLabel?.contains(", merged contact,") == true)
        XCTAssertFalse(mergedLabel?.contains(".,") == true)
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
        let plainRow = app.descendants(matching: .any)["upcoming.row"]
        XCTAssertTrue(plainRow.waitForExistence(timeout: 10))
        let rows = app.descendants(matching: .any).matching(identifier: "upcoming.row")
        let labels = rows.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(
            labels.contains(where: { $0.localizedCaseInsensitiveContains("birthday") }),
            "The representative birthday state must remain reachable and announced."
        )
        XCTAssertTrue(
            labels.contains(where: { $0.localizedCaseInsensitiveContains("anniversary") }),
            "The representative anniversary state must remain reachable and announced."
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
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
        XCTAssertTrue(editButton(in: app).waitForExistence(timeout: 10))
        let plainInteraction = app.descendants(matching: .any)["contact-detail.interaction-row"]
        XCTAssertTrue(
            plainInteraction.waitForExistence(timeout: 5),
            "The representative interaction history must remain reachable on Contact Detail."
        )
        let interactions = app.descendants(matching: .any)
            .matching(identifier: "contact-detail.interaction-row")
            .allElementsBoundByIndex
        XCTAssertTrue(
            interactions.contains { $0.label.contains("WhatsApp, reminder caught up") },
            "The recent interaction must read as one natural-language accessibility element."
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }
}
