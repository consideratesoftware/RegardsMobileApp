import Foundation
import Testing
@testable import Regards

/// Virtual-merge announcements in the shared contact row label.
///
/// Split out of `ContactAccessibilityTests` to keep that suite under the
/// type-body-length limit; the fixtures stay shared.
struct ContactMergeAccessibilityTests {

    @Test("A merged contact announces the merge right after its name")
    func mergedContactAnnouncesMerge() {
        let now = ContactAccessibilityTests.date("2026-04-19 14:00")
        let ctx = Contact.AccessibilityContext(
            now: now,
            effectiveLastInteractedAt: ContactAccessibilityTests.date("2026-04-18 09:00"),
            isOverdue: false,
            overdueDays: 0,
            isVirtualMerged: true)

        let label = ContactAccessibilityTests.makeContact().accessibilityLabel(context: ctx)

        #expect(label.hasPrefix("Priya Raghavan, merged contact,"))
    }

    @Test("An untracked merged contact announces the merge before stopping")
    func untrackedMergedContactAnnouncesMerge() {
        // The `!tracked` branch returns early, so the merge phrase has to be
        // appended before it or a merged, untracked row loses the announcement
        // entirely.
        let ctx = Contact.AccessibilityContext(
            now: Date(),
            effectiveLastInteractedAt: nil,
            isOverdue: false,
            overdueDays: 0,
            isVirtualMerged: true)

        let label = ContactAccessibilityTests.makeContact(tracked: false).accessibilityLabel(context: ctx)

        #expect(label == "Priya Raghavan, merged contact, not tracked.")
    }

    @Test("A merged non-inner-circle contact announces the merge without the tier")
    func mergedNonInnerCircleContactAnnouncesMerge() {
        let now = ContactAccessibilityTests.date("2026-04-19 14:00")
        let ctx = Contact.AccessibilityContext(
            now: now,
            effectiveLastInteractedAt: ContactAccessibilityTests.date("2026-04-12 09:00"),
            isOverdue: true,
            overdueDays: 3,
            isVirtualMerged: true)

        let label = ContactAccessibilityTests.makeContact(priority: .acquaintance)
            .accessibilityLabel(context: ctx)

        #expect(label == "Priya Raghavan, merged contact, 3 days overdue, "
            + "every 14 days, last contacted 1 week ago.")
        #expect(!label.contains("Inner circle"))
    }

    @Test("An unmerged contact never mentions a merge")
    func unmergedContactOmitsTheMergePhrase() {
        let ctx = Contact.AccessibilityContext(
            now: Date(),
            effectiveLastInteractedAt: nil,
            isOverdue: false,
            overdueDays: 0)

        #expect(!ContactAccessibilityTests.makeContact().accessibilityLabel(context: ctx).contains("merged"))
        #expect(!ContactAccessibilityTests.makeContact(tracked: false)
            .accessibilityLabel(context: ctx).contains("merged"))
    }
}
