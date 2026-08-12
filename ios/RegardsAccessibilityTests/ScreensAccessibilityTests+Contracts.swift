import XCTest

extension ScreensAccessibilityTests {
    @MainActor
    func testContactDetailBackReturnsToContacts() {
        let app = launchToContactDetailFromContacts()
        navigate(
            from: "screen.contact-detail",
            to: "screen.contacts",
            triggerDescription: "Contacts back button",
            in: app
        ) {
            app.navigationBars.buttons.element(boundBy: 0)
        }
    }

    @MainActor
    func testMergeCandidateChoicesSurviveTabRoundTrip() {
        let app = launchToSettings(includeDuplicateFixture: true)
        navigateFromSettings(
            triggerIdentifier: "settings.find-duplicate-contacts",
            to: "screen.merge-duplicates",
            in: app
        )

        let plainSelection = app.buttons["merge-duplicates.selection"]
        let plainSecondary = app.buttons["merge-duplicates.primary-b"]
        XCTAssertTrue(plainSelection.waitForExistence(timeout: 10))
        XCTAssertTrue(plainSecondary.waitForExistence(timeout: 10))

        let selection = app.buttons
            .matching(identifier: "merge-duplicates.selection")
            .firstMatch
        let secondary = app.buttons
            .matching(identifier: "merge-duplicates.primary-b")
            .firstMatch
        XCTAssertEqual(selection.label, "Merge virtually")
        XCTAssertTrue(secondary.label.contains("Phone"))
        XCTAssertTrue(secondary.label.contains("+1 415 555 0198"))
        XCTAssertFalse(secondary.label.hasSuffix(", primary"))
        XCTAssertTrue(waitUntilLiveAndHittable(selection))
        activate(selection, attempt: 0)
        XCTAssertEqual(selection.label, "Not a match")
        XCTAssertTrue(waitUntilLiveAndHittable(secondary))
        activate(secondary, attempt: 0)
        XCTAssertTrue(secondary.label.hasSuffix(", primary"))

        navigateToTab(
            named: "Overdue",
            from: "screen.merge-duplicates",
            to: "screen.overdue",
            in: app
        )
        navigateToTab(
            named: "Settings",
            from: "screen.overdue",
            to: "screen.merge-duplicates",
            in: app
        )

        let restoredSelection = app.buttons
            .matching(identifier: "merge-duplicates.selection")
            .firstMatch
        let restoredSecondary = app.buttons
            .matching(identifier: "merge-duplicates.primary-b")
            .firstMatch
        XCTAssertTrue(restoredSelection.exists)
        XCTAssertTrue(restoredSecondary.exists)
        XCTAssertEqual(restoredSelection.label, "Not a match")
        XCTAssertTrue(restoredSecondary.label.hasSuffix(", primary"))
    }

    @MainActor
    func testAccessibility5AdaptiveContentDoesNotOverlap() {
        let app = launchToOverdue(dynamicTypeSize: "accessibility5")
        XCTAssertTrue(
            app.navigationBars["Overdue"].waitForExistence(timeout: 10),
            "The native navigation title should remain exposed at accessibility5."
        )

        let overdueSegment = app.descendants(matching: .any)["regards-segment.overdue"]
        let upcomingSegment = app.descendants(matching: .any)["regards-segment.upcoming"]
        XCTAssertTrue(overdueSegment.waitForExistence(timeout: 10))
        XCTAssertTrue(upcomingSegment.waitForExistence(timeout: 10))
        assertStacked(
            upcomingSegment,
            below: overdueSegment,
            "Accessibility-sized segment options must stack without overlap."
        )

        let digestLead = app.descendants(matching: .any)["overdue.digest-lead"]
        let digestTime = app.descendants(matching: .any)["overdue.digest-time"]
        XCTAssertTrue(digestLead.waitForExistence(timeout: 10))
        XCTAssertTrue(digestTime.waitForExistence(timeout: 10))
        assertStacked(
            digestTime,
            below: digestLead,
            "The digest time must stack below its lead at accessibility sizes."
        )

        navigateToTab(
            named: "Upcoming",
            from: "screen.overdue",
            to: "screen.upcoming",
            in: app
        )
        let plainUpcomingRow = app.descendants(matching: .any)["upcoming.row"]
        XCTAssertTrue(plainUpcomingRow.waitForExistence(timeout: 10))
        let upcomingRows = app.descendants(matching: .any)
            .matching(identifier: "upcoming.row")
            .allElementsBoundByIndex
        guard upcomingRows.count >= 2 else {
            XCTFail("Upcoming should expose at least two rows for overlap verification.")
            return
        }
        assertStacked(
            upcomingRows[1],
            below: upcomingRows[0],
            "Upcoming rows must remain distinct at accessibility sizes."
        )
        navigateToTab(
            named: "Overdue",
            from: "screen.upcoming",
            to: "screen.overdue",
            in: app
        )

        app.descendants(matching: .any)["screen.overdue"].swipeUp()
        let plainOverdueRow = app.descendants(matching: .any)["overdue.row"]
        XCTAssertTrue(plainOverdueRow.waitForExistence(timeout: 10))
        let firstOverdueRow = app.descendants(matching: .any)
            .matching(identifier: "overdue.row")
            .firstMatch
        XCTAssertTrue(
            waitUntilLiveAndHittable(firstOverdueRow, timeout: 3),
            "The first overdue row should be visible and hittable after scrolling."
        )
        let plainFirstChannel = app.descendants(matching: .any)["overdue.channel-unavailable"]
        XCTAssertTrue(plainFirstChannel.waitForExistence(timeout: 10))
        let firstChannel = app.descendants(matching: .any)
            .matching(identifier: "overdue.channel-unavailable")
            .firstMatch
        assertStacked(
            firstChannel,
            below: firstOverdueRow,
            "The channel pill must stack below the contact row at accessibility sizes."
        )
        navigateToRow(
            identifier: "overdue.row",
            index: 0,
            sourceIdentifier: "screen.overdue",
            in: app
        )
        let caughtUp = app.descendants(matching: .any)["contact-detail.caught-up"]
        let snooze = app.descendants(matching: .any)["contact-detail.snooze"]
        let logOther = app.descendants(matching: .any)["contact-detail.log-other"]
        XCTAssertTrue(caughtUp.waitForExistence(timeout: 10))
        XCTAssertTrue(snooze.waitForExistence(timeout: 10))
        XCTAssertTrue(logOther.waitForExistence(timeout: 10))
        assertStacked(snooze, below: caughtUp, "Snooze must stack below Caught up.")
        assertStacked(logOther, below: snooze, "Log other must stack below Snooze.")

        let channelSummary = app.descendants(matching: .any)["contact-detail.channel-summary"]
        let channelChange = app.descendants(matching: .any)["contact-detail.channel-change-unavailable"]
        XCTAssertTrue(channelSummary.waitForExistence(timeout: 10))
        XCTAssertTrue(channelChange.waitForExistence(timeout: 10))
        assertStacked(
            channelChange,
            below: channelSummary,
            "The accessibility-sized channel action must stack below its summary."
        )

        let cadenceValue = app.descendants(matching: .any)["contact-detail.detail-value-every"]
        let cadenceChange = app.descendants(matching: .any)["contact-detail.cadence-change-unavailable"]
        XCTAssertTrue(cadenceValue.waitForExistence(timeout: 10))
        XCTAssertTrue(cadenceChange.waitForExistence(timeout: 10))
        assertStacked(
            cadenceChange,
            below: cadenceValue,
            "The cadence action must stack below its value at accessibility sizes."
        )

        navigate(
            from: "screen.contact-detail",
            to: "screen.edit-contact",
            triggerDescription: "Edit",
            in: app
        ) {
            editButton(in: app)
        }
        let firstName = app.descendants(matching: .any)["edit-contact.field-first"]
        let lastName = app.descendants(matching: .any)["edit-contact.field-last"]
        XCTAssertTrue(firstName.waitForExistence(timeout: 10))
        XCTAssertTrue(lastName.waitForExistence(timeout: 10))
        assertStacked(
            lastName,
            below: firstName,
            "Edit Contact fields must remain distinct at accessibility sizes."
        )
    }

    // MARK: - Row-crowding regression (staged review round 11)

    /// Regression guard for the truncation bug a device screenshot caught on
    /// `a58566e`: real iPhone 17 Pro, contact names clipped to a single
    /// character ("L", "Pad…") next to channel pills clipped to "Wh…"/"Sig…".
    /// Root cause, confirmed by measuring `XCUIElement.frame` before and
    /// after the fix rather than guessing from the screenshot alone:
    /// `OverdueRow.body`'s `HStack` gave the channel pill, Caught up, and
    /// Snooze — each a `Text` in a capsule with no `.lineLimit` and no width
    /// cap — first claim at their own intrinsic width, leaving
    /// `contactButton` (the row's only child with a `Spacer`, so the only
    /// flexible one) to absorb the entire shortfall.
    ///
    /// Present at every Dynamic Type size tested, not only large ones —
    /// Sid's screenshot that started this investigation was actually at the
    /// *smallest* text size. Measured directly (`git show HEAD` before this
    /// commit vs. the code as it now stands, `xSmall` / default):
    ///
    /// | | contactButton | channel pill | Caught up | Snooze |
    /// |---|---|---|---|---|
    /// | pre-fix, xSmall | 78.75pt | 77.8pt | 70.5pt | 71.2pt |
    /// | pre-fix, default | 74.75pt | 74.8pt | 73.8pt | 74.5pt |
    /// | post-fix, xSmall | 134.1pt | 44.5pt | 44.5pt | 44.5pt |
    /// | post-fix, default | 148.4pt | 44.5pt | 44.5pt | 44.5pt |
    ///
    /// The fix (icon-only trailing controls, `ChannelGlyph`'s three shared
    /// symbols) pins the three controls to their 44×44 tap-target minimum
    /// regardless of Dynamic Type size, and the name column gains what they
    /// give up. This test pins both halves of that shape so a future PR that
    /// widens a trailing control — a new text label, extra padding, a badge —
    /// fails here before it reaches a device.
    @MainActor
    func testOverdueRowNameColumnIsNotSqueezedAtSmallestSize() throws {
        let app = launchToOverdue(dynamicTypeSize: "xSmall")
        assertOverdueTrailingControlsStayIconSized(in: app, sizeLabel: "the smallest content size")
    }

    @MainActor
    func testOverdueRowNameColumnIsNotSqueezedAtDefaultSize() throws {
        let app = launchToOverdue()
        assertOverdueTrailingControlsStayIconSized(in: app, sizeLabel: "the default content size")
    }

    @MainActor
    private func assertOverdueTrailingControlsStayIconSized(
        in app: XCUIApplication,
        sizeLabel: String
    ) {
        let row = app.descendants(matching: .any)["overdue.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let channel = app.descendants(matching: .any)["overdue.channel-unavailable"].firstMatch
        let caughtUp = app.descendants(matching: .any)["overdue.caught-up"].firstMatch
        let snooze = app.descendants(matching: .any)["overdue.snooze"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 5))
        XCTAssertTrue(caughtUp.waitForExistence(timeout: 5))
        XCTAssertTrue(snooze.waitForExistence(timeout: 5))

        // Pre-fix these measured 70-78pt (see table above) — a text pill
        // with padding but no width cap. 60pt gives headroom above the
        // fixed ~44.5pt icon size without being so tight a 1pt layout jitter
        // fails the suite.
        for (control, name) in [
            (channel, "the channel pill"),
            (caughtUp, "the caught-up button"),
            (snooze, "the snooze button"),
        ] {
            XCTAssertLessThan(
                control.frame.width, 60,
                "\(name) should stay icon-sized at \(sizeLabel), not reclaim the width"
                    + " a text pill would need."
            )
        }

        // Pre-fix this measured ~75-79pt at both sizes (see table above).
        // 100pt sits well above that and well below the ~134-148pt this
        // fix actually produces, so this fails against the old layout and
        // passes against the current one with real margin either way.
        XCTAssertGreaterThan(
            row.frame.width, 100,
            "The contact name column should measure well over 100pt at \(sizeLabel)."
                + " Pre-fix it measured under 80pt here, which is what let a full name"
                + " collapse to a single character on device."
        )
    }

    /// Same crowding shape as Overdue (`OverdueRow`'s doc comment above),
    /// applied to Upcoming's cadence rows: `UpcomingRow.caughtUpButton` used
    /// to be an unbounded `Text("Caught up")` capsule sitting outside
    /// `rowButton` — the same `Spacer`-owns-the-shortfall layout, just with
    /// one trailing control instead of three, which is why Upcoming
    /// degraded more slowly than Overdue rather than not at all. Not
    /// independently re-measured via a pre-fix revert the way Overdue's
    /// table above was — the source shape before this change (`git show
    /// HEAD` on the commit prior to this PR) is textually identical to
    /// Overdue's old `caughtUpButton` (same `Text`, same padding, same
    /// missing width cap), so the same real proof already gathered there
    /// carries over rather than needing to be repeated.
    @MainActor
    func testUpcomingCaughtUpButtonStaysIconSizedAtSmallestSize() throws {
        let app = launchToOverdue(dynamicTypeSize: "xSmall")
        navigateToTab(named: "Upcoming", from: "screen.overdue", to: "screen.upcoming", in: app)
        assertUpcomingCaughtUpButtonStaysIconSized(in: app, sizeLabel: "the smallest content size")
    }

    @MainActor
    func testUpcomingCaughtUpButtonStaysIconSizedAtDefaultSize() throws {
        let app = launchToOverdue()
        navigateToTab(named: "Upcoming", from: "screen.overdue", to: "screen.upcoming", in: app)
        assertUpcomingCaughtUpButtonStaysIconSized(in: app, sizeLabel: "the default content size")
    }

    @MainActor
    private func assertUpcomingCaughtUpButtonStaysIconSized(
        in app: XCUIApplication,
        sizeLabel: String
    ) {
        let plainCaughtUp = app.descendants(matching: .any)["upcoming.caught-up"]
        XCTAssertTrue(plainCaughtUp.waitForExistence(timeout: 10))
        let caughtUp = app.descendants(matching: .any)
            .matching(identifier: "upcoming.caught-up")
            .firstMatch
        XCTAssertLessThan(
            caughtUp.frame.width, 60,
            "Upcoming's Caught up button should stay icon-sized at \(sizeLabel), matching"
                + " Overdue's — a wide text pill here would squeeze the same"
                + " Spacer-owned name column `rowButton` shares that shape with."
        )
    }

    @MainActor
    func testUnavailableActionsAreDescribedAndNoninteractive() {
        let app = launchToOverdue()
        assertUnavailableElement(
            identifier: "overdue.channel-unavailable",
            expectedLabel: nil,
            in: app
        )
        navigateToRow(
            identifier: "overdue.row",
            index: 0,
            sourceIdentifier: "screen.overdue",
            in: app
        )

        let unavailableElements = [
            ("contact-detail.open-channel-unavailable", "Open WhatsApp, unavailable"),
            ("contact-detail.cadence-change-unavailable", "Change, unavailable"),
            ("contact-detail.channel-change-unavailable", "Change, unavailable"),
        ]
        for (identifier, expectedLabel) in unavailableElements {
            assertUnavailableElement(
                identifier: identifier,
                expectedLabel: expectedLabel,
                in: app
            )
        }

        // Caught up / Snooze / Log other are wired (§14 PR22): real,
        // hittable controls, not muted unavailable text.
        let caughtUp = app.descendants(matching: .any)["contact-detail.caught-up"]
        let snooze = app.descendants(matching: .any)["contact-detail.snooze"]
        let logOther = app.descendants(matching: .any)["contact-detail.log-other"]
        XCTAssertTrue(caughtUp.waitForExistence(timeout: 10))
        XCTAssertTrue(snooze.waitForExistence(timeout: 10))
        XCTAssertTrue(logOther.waitForExistence(timeout: 10))
        XCTAssertEqual(caughtUp.label, "Caught up")
        // Spelled out, not the on-screen "1 wk" — VoiceOver reads that
        // abbreviation literally. No contact name here, unlike Overdue and
        // Upcoming's row buttons; see the label's own comment for why.
        XCTAssertEqual(snooze.label, "Snooze 1 week")
        XCTAssertEqual(logOther.label, "Log other")
        XCTAssertTrue(caughtUp.isEnabled)
        XCTAssertTrue(snooze.isEnabled)
        XCTAssertTrue(logOther.isEnabled)
    }
}
