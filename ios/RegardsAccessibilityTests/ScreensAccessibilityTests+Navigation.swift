import XCTest

extension ScreensAccessibilityTests {
    // MARK: - Helpers

    @MainActor
    func launchToOverdue() -> XCUIApplication {
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
    func launchToSettings() -> XCUIApplication {
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
    func launchToContactDetailFromContacts() -> XCUIApplication {
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
        // Re-resolve for two bounded retries because rapid test relaunches can
        // drop synthesized row taps before SwiftUI handles them.
        for _ in 0..<3 {
            if detail.exists, !contacts.exists {
                break
            }

            let firstRow = contacts.descendants(matching: .button).firstMatch
            guard waitUntilLiveAndHittable(firstRow, timeout: 10) else {
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
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func navigateToTab(
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

        // Rapid simulator relaunches can leave a stale tab-bar element in the
        // automation hierarchy. Resolve the current button for each attempt
        // and allow two bounded retries when synthesized taps are dropped.
        // The screen waits remain plain queries. The bounded hittability poll
        // below returns false without recording an XCTest failure while a
        // transient element has no activation frame.
        for _ in 0..<3 {
            if destination.exists, !source.exists {
                return
            }

            let tabBar = app.tabBars.firstMatch
            guard tabBar.waitForExistence(timeout: 10) else {
                continue
            }

            let button = app.tabBars.buttons[name]
            guard waitUntilLiveAndHittable(button) else {
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
    func navigateFromSettings(
        triggerIdentifier: String,
        to screenIdentifier: String,
        in app: XCUIApplication
    ) {
        let source = app.descendants(matching: .any)["screen.settings"]
        let destination = app.descendants(matching: .any)[screenIdentifier]
        XCTAssertTrue(
            source.waitForExistence(timeout: 10),
            "Settings should exist before opening \(screenIdentifier)."
        )

        for _ in 0..<3 {
            if destination.exists, !source.exists {
                return
            }

            let trigger = app.descendants(matching: .any)[triggerIdentifier]
            guard waitUntilLiveAndHittable(trigger) else {
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
    func navigateToRow(
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
        for _ in 0..<3 {
            if detail.exists, !source.exists {
                return
            }

            guard plainRow.waitForExistence(timeout: 10) else {
                continue
            }
            let rows = app.descendants(matching: .any)
                .matching(identifier: identifier)
                .allElementsBoundByIndex
            guard rows.indices.contains(index),
                  waitUntilLiveAndHittable(rows[index]) else {
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
    func navigate(
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

        for _ in 0..<3 {
            if destination.exists, !source.exists {
                return
            }

            let liveTrigger = trigger()
            guard waitUntilLiveAndHittable(liveTrigger) else {
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
    func assertEditRoundTrip(in app: XCUIApplication) {
        navigate(
            from: "screen.contact-detail",
            to: "screen.edit-contact",
            triggerDescription: "Edit",
            in: app
        ) {
            app.navigationBars.buttons["Edit"]
        }
        assertReadOnlyBanner(in: app)
        navigate(
            from: "screen.edit-contact",
            to: "screen.contact-detail",
            triggerDescription: "Contact back button",
            in: app
        ) {
            app.navigationBars.buttons["Contact"]
        }
        XCTAssertTrue(app.navigationBars.buttons["Edit"].waitForExistence(timeout: 10))
    }

    @MainActor
    func assertReadOnlyBanner(in app: XCUIApplication) {
        let banner = app.staticTexts["edit-contact.read-only-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertEqual(
            banner.label,
            "Read-only preview. Contact editing is not available yet; your device Contacts stay unchanged."
        )
    }

    @MainActor
    func tapLiveCoordinate(of element: XCUIElement) {
        // Center-coordinate taps work around the simulator's dropped-tap
        // race. They are navigation synchronization only; the audit still
        // owns hit-region verification when sensory categories are enabled.
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
    }

    @MainActor
    func waitUntilLiveAndHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline

        return element.exists && element.isHittable
    }

}
