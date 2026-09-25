import XCTest

@MainActor
private final class ElementHittabilityPoller: NSObject {
    let element: XCUIElement
    let expectation: XCTestExpectation

    init(element: XCUIElement, expectation: XCTestExpectation) {
        self.element = element
        self.expectation = expectation
    }

    @objc func poll(_ timer: Timer) {
        guard element.exists, element.isHittable else { return }
        timer.invalidate()
        expectation.fulfill()
    }
}

extension ScreensAccessibilityTests {
    // MARK: - Helpers

    @MainActor
    func launchToOverdue(
        dynamicTypeSize: String? = nil,
        includeDuplicateFixture: Bool = false,
        seedCorruptRow: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append("--regards-mock-runtime")
        if let dynamicTypeSize {
            app.launchEnvironment["REGARDS_UI_TEST_DYNAMIC_TYPE"] = dynamicTypeSize
        }
        if includeDuplicateFixture {
            app.launchEnvironment["REGARDS_UI_TEST_DUPLICATE_FIXTURE"] = "1"
        }
        if seedCorruptRow {
            app.launchEnvironment["REGARDS_UI_TEST_SEED_CORRUPT_ROW"] = "1"
        }
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
    func launchToSettings(includeDuplicateFixture: Bool = false) -> XCUIApplication {
        let app = launchToOverdue(includeDuplicateFixture: includeDuplicateFixture)
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

        // Contacts rows resolve as buttons, not the synthetic `.other`
        // elements Overdue/Upcoming use. Two bounded retries: rapid test
        // relaunches can drop a synthesized row tap before SwiftUI handles it.
        for attempt in 0..<3 {
            if detail.exists, !contacts.exists {
                break
            }

            let firstRow = contacts.descendants(matching: .button).firstMatch
            guard waitUntilLiveAndHittable(firstRow, timeout: 10) else {
                continue
            }
            activate(firstRow, attempt: attempt)
            if detail.waitForExistence(timeout: 10),
               contacts.waitForNonExistence(timeout: 10) {
                break
            }
        }

        XCTAssertTrue(
            detail.exists && !contacts.exists,
            "The first Contacts row should replace Contacts with Contact Detail."
        )
        XCTAssertTrue(editButton(in: app).waitForExistence(timeout: 10))
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

        // A prior scroll on `source` can leave the floating tab bar
        // minimized (`RegardsTabBarBehavior`'s `tabBarMinimizeBehavior
        // (.onScrollDown)`, iOS 26+) — standard system behavior, not a bug:
        // a real user scrolls back up before tapping a different tab, and
        // the minimized bar's other buttons are genuinely absent from the
        // tree meanwhile (dumped directly: 4 buttons before a scroll, 2
        // after — removed, not relabeled). `source` is the screen's own
        // `List`; scrolling it up reproduces that precondition instead of
        // working around a synthetic-only problem. Bounded loop, not one
        // `swipeDown()`: a single swipe wasn't reliably enough distance to
        // cross the re-expand threshold, and expanding is itself a brief
        // animation this also waits out. Skipped when nothing minimized it.
        if !app.tabBars.buttons[name].exists {
            for _ in 0..<4 {
                source.swipeDown()
                if waitUntilLiveAndHittable(app.tabBars.buttons[name], timeout: 2) {
                    break
                }
            }
        }

        // Rapid simulator relaunches can leave a stale tab-bar element in the
        // tree. Resolve the current button per attempt with two bounded
        // retries when synthesized taps are dropped; the hittability poll
        // below returns false, without failing, while a transient element
        // has no activation frame yet.
        for attempt in 0..<3 {
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
            activate(button, attempt: attempt)
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

        for attempt in 0..<3 {
            if destination.exists, !source.exists {
                return
            }

            let trigger = app.descendants(matching: .any)[triggerIdentifier]
            guard waitUntilLiveAndHittable(trigger) else {
                continue
            }
            activate(trigger, attempt: attempt)
            if destination.waitForExistence(timeout: 10),
               source.waitForNonExistence(timeout: 10) {
                return
            }
        }

        XCTFail("\(triggerIdentifier) should replace Settings with \(screenIdentifier).")
    }

    /// Opens Contact Detail for a specific contact by name via Contacts —
    /// the only surviving route from Overdue or Upcoming as of round 12
    /// (`ARCHITECTURE.md` R52), for any test that needs a *specific* named
    /// contact rather than just "whichever is first". Contacts rows have no
    /// shared stable identifier (see `launchToContactDetailFromContacts`'s
    /// matching comment); this matches on the row's combined label, which
    /// begins with `displayName`.
    @MainActor
    func openContactDetail(
        named name: String,
        fromTabIdentifier sourceIdentifier: String,
        in app: XCUIApplication
    ) {
        navigateToTab(named: "Contacts", from: sourceIdentifier, to: "screen.contacts", in: app)
        let contactsScreen = app.descendants(matching: .any)["screen.contacts"]
        let detail = app.descendants(matching: .any)["screen.contact-detail"]
        let contactsRow = app.buttons
            .element(matching: NSPredicate(format: "label BEGINSWITH[c] %@", name))

        for attempt in 0..<3 {
            if detail.exists { return }
            // Bounded-scroll fallback: at accessibility Dynamic Type sizes,
            // or simply further down an alphabetical list, the named row
            // can be genuinely off-screen rather than merely not settled.
            if !waitUntilLiveAndHittable(contactsRow) {
                contactsScreen.swipeUp()
                if !waitUntilLiveAndHittable(contactsRow) {
                    contactsScreen.swipeDown()
                    guard waitUntilLiveAndHittable(contactsRow) else { continue }
                }
            }
            activate(contactsRow, attempt: attempt)
            if detail.waitForExistence(timeout: 10) { return }
        }

        XCTFail("The Contacts row for \(name) should open Contact Detail.")
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

        for attempt in 0..<3 {
            if destination.exists, !source.exists {
                return
            }

            let liveTrigger = trigger()
            guard waitUntilLiveAndHittable(liveTrigger) else {
                continue
            }
            activate(liveTrigger, attempt: attempt)
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
            editButton(in: app)
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
        XCTAssertTrue(editButton(in: app).waitForExistence(timeout: 10))
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
    func assertUnavailableElement(
        identifier: String,
        expectedLabel: String?,
        in app: XCUIApplication
    ) {
        let plainElement = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(
            plainElement.waitForExistence(timeout: 10),
            "\(identifier) should exist as unavailable content."
        )
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        XCTAssertGreaterThan(
            matches.count,
            0,
            "\(identifier) should remain available for trait assertions."
        )
        let element = matches.firstMatch
        XCTAssertTrue(element.label.hasSuffix(", unavailable"))
        if let expectedLabel {
            XCTAssertEqual(element.label, expectedLabel)
        }
        XCTAssertEqual(
            app.buttons.matching(identifier: identifier).count,
            0,
            "\(identifier) must not expose a button trait before it is wired."
        )
    }

    @MainActor
    func activate(_ element: XCUIElement, attempt: Int) {
        // Simulator automation can drop a synthesized tap on a live element.
        // Bounded retries vary the target point; the caller verifies
        // source/destination state after every attempt. Navigation sync
        // only — the audit still owns hit-region verification.
        let offsets = [0.5, 0.35, 0.65]
        let offset = offsets[min(attempt, offsets.count - 1)]
        element.coordinate(
            withNormalizedOffset: CGVector(dx: offset, dy: 0.5)
        ).tap()
    }

    @MainActor
    func waitUntilLiveAndHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 2
    ) -> Bool {
        if element.exists, element.isHittable { return true }

        let live = XCTestExpectation(description: "Element becomes live and hittable")
        let target = ElementHittabilityPoller(element: element, expectation: live)
        let timer = Timer.scheduledTimer(
            timeInterval: 0.05,
            target: target,
            selector: #selector(ElementHittabilityPoller.poll(_:)),
            userInfo: nil,
            repeats: true
        )
        defer { timer.invalidate() }

        return XCTWaiter.wait(for: [live], timeout: timeout) == .completed
    }

}
