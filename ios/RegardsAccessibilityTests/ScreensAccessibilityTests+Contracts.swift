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
        assertOverdueHeaderRemainsStackedAtAccessibility5(in: app)
        let targetName = assertRowsRemainStackedAtAccessibility5(in: app)

        // Reroutes through Contacts, round 12: Overdue's row no longer
        // pushes Contact Detail (see `ARCHITECTURE.md` R52); the rest of
        // this test needs *a* Contact Detail, not specifically Overdue's, so
        // it takes the surviving route with whichever contact is first on
        // Overdue right now.
        openContactDetail(named: targetName, fromTabIdentifier: "screen.overdue", in: app)
        assertContactDetailAndEditContactRemainStackedAtAccessibility5(in: app)
    }

    /// Split out of `testAccessibility5AdaptiveContentDoesNotOverlap` (round
    /// 12, purely to keep that function under the linter's body-length
    /// limit) — the segmented control and digest row, unaffected by round
    /// 12's changes.
    @MainActor
    private func assertOverdueHeaderRemainsStackedAtAccessibility5(in app: XCUIApplication) {
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
    }

    /// Split out of `testAccessibility5AdaptiveContentDoesNotOverlap` — see
    /// that function's own note. Returns the name on Overdue's first row
    /// (extracted from its combined label) so the caller can open that same
    /// contact's Contact Detail next.
    @MainActor
    private func assertRowsRemainStackedAtAccessibility5(in app: XCUIApplication) -> String {
        navigateToTab(named: "Upcoming", from: "screen.overdue", to: "screen.upcoming", in: app)
        // `List` is a lazy, virtualized `UICollectionView` (see
        // `LogOtherChannelSheet`'s doc comment for the same fact elsewhere
        // in this suite): at accessibility5 the header above the sectioned
        // rows (subtitle, segmented control, digest text) is tall enough
        // that the first row is not instantiated without a scroll — the
        // Overdue side of this same check already needed this (below); this
        // was the one place it was still missing.
        app.descendants(matching: .any)["screen.upcoming"].swipeUp()
        let plainUpcomingRow = app.descendants(matching: .any)["upcoming.row"]
        XCTAssertTrue(plainUpcomingRow.waitForExistence(timeout: 10))
        let upcomingRows = app.descendants(matching: .any)
            .matching(identifier: "upcoming.row")
            .allElementsBoundByIndex
        if upcomingRows.count >= 2 {
            assertStacked(
                upcomingRows[1],
                below: upcomingRows[0],
                "Upcoming rows must remain distinct at accessibility sizes."
            )
        } else {
            XCTFail("Upcoming should expose at least two rows for overlap verification.")
        }
        navigateToTab(named: "Overdue", from: "screen.upcoming", to: "screen.overdue", in: app)

        app.descendants(matching: .any)["screen.overdue"].swipeUp()
        let plainOverdueRow = app.descendants(matching: .any)["overdue.row"]
        XCTAssertTrue(plainOverdueRow.waitForExistence(timeout: 10))
        let overdueRows = app.descendants(matching: .any)
            .matching(identifier: "overdue.row")
            .allElementsBoundByIndex
        let firstOverdueRow = overdueRows[0]
        XCTAssertTrue(
            waitUntilLiveAndHittable(firstOverdueRow, timeout: 3),
            "The first overdue row should be visible and hittable after scrolling."
        )
        // Was a channel-pill-vs-row stacking check (`overdue.channel
        // -unavailable`) — that identifier is gone (round 12: `ChannelGlyph`
        // is decorative-only now, folded into the row's own single
        // accessibility element, not a separately identified control — see
        // `OverdueRow`'s doc comment). Row-vs-row is the equivalent
        // still-live concern, mirroring the Upcoming-rows check above.
        if overdueRows.count >= 2 {
            assertStacked(
                overdueRows[1],
                below: overdueRows[0],
                "Overdue rows must remain distinct at accessibility sizes."
            )
        } else {
            XCTFail("Overdue should expose at least two rows for overlap verification.")
        }

        return String(firstOverdueRow.label.split(separator: ",").first ?? Substring(firstOverdueRow.label))
    }

    /// Split out of `testAccessibility5AdaptiveContentDoesNotOverlap` (round
    /// 12) purely to keep that function under the linter's body-length
    /// limit once it grew a Contacts reroute and an extra row-stacking
    /// check — no behavior change, same assertions in the same order.
    @MainActor
    private func assertContactDetailAndEditContactRemainStackedAtAccessibility5(in app: XCUIApplication) {
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

    // MARK: - Row-crowding regression (staged review round 11, rewritten round 12)

    /// Regression guard for the truncation bug a device screenshot caught on
    /// `a58566e`: real iPhone 17 Pro, contact names clipped to a single
    /// character ("L", "Pad…") next to channel pills clipped to "Wh…"/"Sig…".
    ///
    /// Rewritten, round 12: the original fix (icon-only `Caught up`/`Snooze`
    /// buttons alongside `ChannelGlyph`) pinned those three controls to a
    /// fixed 44×44 size and asserted the row measured comfortably wider than
    /// its pre-fix ~75-79pt as an indirect proxy — because at the time, that
    /// indirect proxy was the only one available; the controls it measured
    /// no longer exist to measure (round 12 moved Caught up / Snooze off the
    /// row entirely, onto `.swipeActions` — see `ARCHITECTURE.md` R52), and
    /// `ChannelGlyph` is a small fixed-size decorative icon with nothing
    /// else beside it competing for width. That means what's actually worth
    /// asserting now is more direct, not less: the row itself — one `Button`
    /// spanning the full card width, per `OverdueRow.body` — should measure
    /// close to that full width, not some fraction of it. The row also
    /// collapses to a single accessibility element (`.accessibilityElement
    /// (children: .ignore)`), so the name `Text` inside it isn't itself
    /// independently queryable any more — the row's own frame is the most
    /// direct thing XCUITest can measure here.
    @MainActor
    func testOverdueRowIsNotSqueezedAtSmallestSize() {
        let app = launchToOverdue(dynamicTypeSize: "xSmall")
        assertOverdueRowReclaimsFullWidth(in: app, sizeLabel: "the smallest content size")
    }

    @MainActor
    func testOverdueRowIsNotSqueezedAtDefaultSize() {
        let app = launchToOverdue()
        assertOverdueRowReclaimsFullWidth(in: app, sizeLabel: "the default content size")
    }

    @MainActor
    private func assertOverdueRowReclaimsFullWidth(
        in app: XCUIApplication,
        sizeLabel: String
    ) {
        let row = app.descendants(matching: .any)["overdue.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        // Pre-fix (`a58566e`) this measured under 80pt at every size tested
        // (see this test's own doc comment). Post-round-12, with nothing
        // left on the row to compete with the name but one small fixed-size
        // decorative glyph, it measures well over 300pt on the dedicated
        // test simulator (402pt-wide device, `.insetGrouped` List margins).
        // 250pt sits with real margin below that measured value and with
        // even more margin above the old cramped layout — high enough that
        // a future regression reintroducing a wide inline control would
        // fail here, low enough that normal per-device/per-size layout
        // jitter won't.
        XCTAssertGreaterThan(
            row.frame.width, 250,
            "The Overdue row should reclaim close to the full card width at \(sizeLabel)."
                + " Pre-fix it measured under 80pt here, which is what let a full name"
                + " collapse to a single character on device."
        )
    }

    /// Same crowding shape as Overdue (`OverdueRow`'s doc comment above),
    /// applied to Upcoming's rows. Rewritten, round 12, for the identical
    /// reason: `UpcomingRow.caughtUpButton` (an unbounded `Text` capsule)
    /// moved off the row onto `.swipeActions`, so there is nothing left
    /// beside the name but `time` (a short, fixed-format string) and a small
    /// fixed-size `ChannelGlyph` — the row itself is the direct thing to
    /// measure now, same as Overdue.
    @MainActor
    func testUpcomingRowIsNotSqueezedAtSmallestSize() {
        let app = launchToOverdue(dynamicTypeSize: "xSmall")
        navigateToTab(named: "Upcoming", from: "screen.overdue", to: "screen.upcoming", in: app)
        assertUpcomingRowReclaimsFullWidth(in: app, sizeLabel: "the smallest content size")
    }

    @MainActor
    func testUpcomingRowIsNotSqueezedAtDefaultSize() {
        let app = launchToOverdue()
        navigateToTab(named: "Upcoming", from: "screen.overdue", to: "screen.upcoming", in: app)
        assertUpcomingRowReclaimsFullWidth(in: app, sizeLabel: "the default content size")
    }

    @MainActor
    private func assertUpcomingRowReclaimsFullWidth(
        in app: XCUIApplication,
        sizeLabel: String
    ) {
        let row = app.descendants(matching: .any)["upcoming.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(
            row.frame.width, 250,
            "The Upcoming row should reclaim close to the full card width at \(sizeLabel),"
                + " matching Overdue's — see that test's doc comment for the pre-fix baseline"
                + " both rows shared."
        )
    }

    /// Was, in part, a check that Overdue's channel pill (`overdue.channel
    /// -unavailable`) exposed no button trait before it was wired. That
    /// identifier — and the "unavailable" framing it carried — is gone
    /// (round 12): `ChannelGlyph` is now purely decorative, folded into the
    /// row's single accessibility element (`.accessibilityElement(children:
    /// .ignore)`), so it's structurally incapable of exposing its own trait
    /// at all any more, the same way any other decorative content inside an
    /// ignored-children container is. That's a stronger guarantee than the
    /// old assertion gave, not a weaker one — proven here as a negative:
    /// the identifier the old shape depended on must not exist anywhere on
    /// screen. Rerouted to Contact Detail through Contacts, round 12 (see
    /// `ARCHITECTURE.md` R52): Overdue's row no longer pushes there.
    @MainActor
    func testUnavailableActionsAreDescribedAndNoninteractive() {
        let app = launchToOverdue()
        XCTAssertFalse(
            app.descendants(matching: .any)["overdue.channel-unavailable"].exists,
            "Overdue's channel glyph is decorative-only now (round 12) — it should carry no"
                + " identifier of its own, unavailable or otherwise."
        )
        openContactDetail(named: "Leia Organa", fromTabIdentifier: "screen.overdue", in: app)

        let unavailableElements = [
            ("contact-detail.open-channel-unavailable", "Open WhatsApp, unavailable"),
            ("contact-detail.cadence-change-unavailable", "Change, unavailable"),
            ("contact-detail.channel-change-unavailable", "Change, unavailable")
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
