import Foundation
import Testing
@testable import Regards

struct ContactAccessibilityTests {

    static func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: iso)!
    }

    static func makeContact(
        name: String = "Priya Raghavan",
        cadence: Int? = 14,
        tracked: Bool = true,
        priority: PriorityTier = .innerCircle
    ) -> Contact {
        Contact(systemContactRef: "sys",
                displayName: name,
                tracked: tracked,
                cadenceDays: cadence,
                priorityTier: priority,
                preferredChannel: .whatsapp,
                preferredChannelValue: "+919876543210")
    }

    @Test("Overdue label reads as a natural sentence")
    func overdueLabel() {
        let now = Self.date("2026-04-19 14:00")
        let last = Self.date("2026-03-29 09:00")
        let ctx = Contact.AccessibilityContext(
            now: now, effectiveLastInteractedAt: last,
            isOverdue: true, overdueDays: 9)
        let c = Self.makeContact()
        let label = c.accessibilityLabel(context: ctx)
        #expect(label.contains("Priya Raghavan"))
        #expect(label.contains("9 days overdue"))
        #expect(label.contains("every 14 days"))
        #expect(label.contains("last contacted 3 weeks ago"))
        #expect(label.hasSuffix("Inner circle."))
    }

    @Test("Pluralization at boundaries (0, 1, 2)")
    func pluralization() {
        let now = Date()
        let ctx1 = Contact.AccessibilityContext(
            now: now, effectiveLastInteractedAt: nil, isOverdue: true, overdueDays: 1)
        let c1 = Self.makeContact(cadence: 1)
        let label1 = c1.accessibilityLabel(context: ctx1)
        #expect(label1.contains("1 day overdue"))
        #expect(label1.contains("every 1 day"))

        let ctx0 = Contact.AccessibilityContext(
            now: now, effectiveLastInteractedAt: nil, isOverdue: true, overdueDays: 0)
        let c0 = Self.makeContact()
        let label0 = c0.accessibilityLabel(context: ctx0)
        #expect(label0.contains("0 days overdue"))
    }

    @Test("Relative time covers today, yesterday, weeks, months, years")
    func relativeTime() {
        let now = Self.date("2026-04-19 14:00")
        #expect(Contact.relativeDescription(for: nil, from: now) == nil)
        #expect(Contact.relativeDescription(for: now.addingTimeInterval(-3600), from: now) == "today")
        #expect(Contact.relativeDescription(for: now.addingTimeInterval(-86400 * 1.5), from: now) == "yesterday")
        #expect(Contact.relativeDescription(for: now.addingTimeInterval(-86400 * 3), from: now) == "3 days ago")
        #expect(Contact.relativeDescription(for: now.addingTimeInterval(-86400 * 7), from: now) == "1 week ago")
        #expect(Contact.relativeDescription(for: now.addingTimeInterval(-86400 * 22), from: now) == "3 weeks ago")
        #expect(Contact.relativeDescription(for: now.addingTimeInterval(-86400 * 45), from: now) == "1 month ago")
        #expect(Contact.relativeDescription(for: now.addingTimeInterval(-86400 * 400), from: now) == "1 year ago")
    }

    @Test("Untracked contact's label flags state instead of cadence")
    func untrackedLabel() {
        let now = Date()
        let ctx = Contact.AccessibilityContext(
            now: now, effectiveLastInteractedAt: nil, isOverdue: false, overdueDays: 0)
        let c = Self.makeContact(tracked: false)
        let label = c.accessibilityLabel(context: ctx)
        #expect(label.contains("not tracked"))
        #expect(!label.contains("every"))
    }

    @Test("Status chip mirrors the overdue state")
    func statusChip() {
        let now = Date()
        let overdue = Contact.AccessibilityContext(
            now: now, effectiveLastInteractedAt: nil, isOverdue: true, overdueDays: 9)
        let onTime = Contact.AccessibilityContext(
            now: now, effectiveLastInteractedAt: nil, isOverdue: false, overdueDays: 0)
        #expect(Self.makeContact().statusChip(context: overdue) == "9d overdue")
        #expect(Self.makeContact().statusChip(context: onTime) == nil)
    }

    @Test("Contact Preview speaks email punctuation")
    func contactPreviewEmailSpeech() {
        let label = EditContactAccessibility.fieldLabel(
            "personal",
            value: "obiwan@jeditemple.org",
            placeholder: "Add email",
            speech: .email
        )

        #expect(label == "personal, obiwan at jeditemple dot org")
    }

    @Test("Contact Preview preserves non-email punctuation")
    func contactPreviewVerbatimSpeech() {
        let label = EditContactAccessibility.fieldLabel(
            "Handle",
            value: "@jedi.temple",
            placeholder: "Add handle",
            speech: .verbatim
        )

        #expect(label == "Handle, @jedi.temple")
    }
}
