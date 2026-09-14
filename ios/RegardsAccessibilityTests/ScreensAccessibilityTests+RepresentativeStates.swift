import XCTest

extension ScreensAccessibilityTests {
    @MainActor
    func testOverdueTabPassesAudit() throws {
        let app = launchToOverdue()
        let plainRow = app.descendants(matching: .any)["overdue.row"]
        XCTAssertTrue(plainRow.waitForExistence(timeout: 10))
        // No merged-contact announcement check here (staged review round
        // 11): the "merged" chip and its spoken phrase were both removed
        // from Overdue's row — merge provenance lives on Merge Duplicates
        // alone now, by decision, since it's identity-management
        // information no other surface asks the user to act on. Proving
        // the negative directly, not just relying on absence-of-evidence:
        // no row's label should mention a merge at all any more.
        let rows = app.descendants(matching: .any).matching(identifier: "overdue.row")
        let stillMentionsMerge = rows.allElementsBoundByIndex.contains {
            $0.label.localizedCaseInsensitiveContains("merged")
        }
        XCTAssertFalse(
            stillMentionsMerge,
            "No Overdue row should mention a merge — that state moved to Merge Duplicates only."
        )
        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// `List` only materializes rows near the visible viewport (a lazy,
    /// virtualized `UICollectionView` — see `LogOtherChannelSheet`'s doc
    /// comment for the same fact elsewhere in this suite). The birthday row
    /// is in the fixture's first day section, but the anniversary row is
    /// several sections down — round 12 (`ARCHITECTURE.md` R52, the `List`
    /// migration) means neither is guaranteed to exist without scrolling any
    /// more, unlike under the old eagerly-rendered `ScrollView`. Collects
    /// every row's label across bounded scrolls rather than assuming a
    /// single snapshot has everything.
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
        let labels = collectAllUpcomingRowLabels(in: app)
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

    /// Scrolls Upcoming in bounded steps, collecting every distinct
    /// `upcoming.row` label seen along the way, until two consecutive
    /// scrolls surface nothing new (the bottom) or the scroll budget runs
    /// out — see `testUpcomingTabPassesAudit`'s doc comment for why a single
    /// snapshot isn't enough under `List`'s virtualization.
    @MainActor
    private func collectAllUpcomingRowLabels(in app: XCUIApplication, maxScrolls: Int = 8) -> [String] {
        let upcomingScreen = app.descendants(matching: .any)["screen.upcoming"]
        var seen: [String] = []
        var seenSet: Set<String> = []
        func capture() {
            let rows = app.descendants(matching: .any)
                .matching(identifier: "upcoming.row")
                .allElementsBoundByIndex
            for row in rows where seenSet.insert(row.label).inserted {
                seen.append(row.label)
            }
        }
        capture()
        for _ in 0..<maxScrolls {
            let before = seenSet.count
            upcomingScreen.swipeUp()
            capture()
            if seenSet.count == before { break }
        }
        return seen
    }

    /// R50 (TF-03 / PR21): a stored `Contact` row that fails to decode must
    /// stay visible on All Contacts, with a banner surfacing the diagnostic,
    /// instead of the whole screen going unavailable. This can only be
    /// proven with real assistive technology active — SwiftUI's UIKit-facing
    /// accessibility tree doesn't materialize in a plain hosted unit test,
    /// only here, where an `XCUIApplication` talks to the real accessibility
    /// server.
    @MainActor
    func testContactsCorruptionBannerPassesAudit() throws {
        let app = launchToOverdue(seedCorruptRow: true)
        navigateToTab(
            named: "Contacts",
            from: "screen.overdue",
            to: "screen.contacts",
            in: app
        )

        let banner = app.descendants(matching: .any)["contacts.corruption-banner"]
        XCTAssertTrue(
            banner.waitForExistence(timeout: 10),
            "The corruption banner must remain reachable when a stored row can't be read."
        )
        XCTAssertEqual(
            banner.label,
            "1 contact couldn't be read and needs attention.",
            "The banner's combined accessibility label must equal the visible message exactly"
                + " — a passing icon glyph would append extra text."
        )
        // The seeded cast's healthy rows must stay usable alongside the
        // banner, not just present in some non-visible form — reuse the same
        // first-row activation `launchToContactDetailFromContacts` relies on
        // (All Contacts rows have no shared stable identifier to query by).
        let firstRow = app.descendants(matching: .any)["screen.contacts"]
            .descendants(matching: .button).firstMatch
        XCTAssertTrue(
            waitUntilLiveAndHittable(firstRow, timeout: 10),
            "A healthy contact row must remain reachable alongside the corruption banner."
        )

        try app.performAccessibilityAudit(for: Self.structuralAuditCategories)
    }

    /// Exercises the representative interaction-history state on Contact
    /// Detail. Reroutes through Contacts, round 12: this used to reach
    /// Contact Detail via an Overdue row tap; that tap now opens the
    /// channel-preview alert instead (`ARCHITECTURE.md` R52; see
    /// `ScreensAccessibilityTests+RowActions.swift`'s
    /// `testOverdueChannelPreviewPassesAuditAndDismisses` for that
    /// coverage). This test's real subject was always Contact Detail's
    /// interaction list, not how you get there, so it moved to the route
    /// that still reaches it — Leia Organa specifically, since she's the
    /// one fixture contact seeded with the "WhatsApp, reminder caught up"
    /// interaction this test pins (`MockRepositories.swift`).
    @MainActor
    func testContactDetailInteractionHistoryPassesAudit() throws {
        let app = launchToOverdue()
        openContactDetail(named: "Leia Organa", fromTabIdentifier: "screen.overdue", in: app)
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
