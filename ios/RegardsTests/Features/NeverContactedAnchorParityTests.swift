import Foundation
import Testing
@testable import Regards

/// Blocker (staged review): `ContactDetailViewModel.overdueSummary` used to
/// guard on `lastInteractedAt` alone, reporting "on track" for a tracked,
/// never-contacted contact — a third, disagreeing implementation of the
/// never-contacted anchor (decision #29 / R8) that `OverdueViewModel
/// .makeOverdueRow` and `UpcomingViewModel.buildRows` already got right
/// (`lastInteractedAt ?? createdAt`). This pins all three surfaces against
/// the *same* never-contacted fixture, so a future regression in any one of
/// them shows up here even if that surface's own suite doesn't happen to
/// cover a nil-`lastInteractedAt` contact.
@MainActor
struct NeverContactedAnchorParityTests {
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Never contacted (`lastInteractedAt: nil`), created 100 days ago,
    /// 14-day cadence — `ContactDetailViewModelTests.contact(...)`'s own
    /// default shape, which is exactly the case the blocker got wrong.
    static func neverContactedContact(id: UUID = UUID()) -> Contact {
        Contact(
            id: id,
            systemContactRef: "sys-\(id.uuidString)",
            displayName: "Leia Organa",
            tracked: true,
            cadenceDays: 14,
            priorityTier: .close,
            preferredChannel: .whatsapp,
            preferredChannelValue: "+14155550140",
            lastInteractedAt: nil,
            createdAt: Self.now.addingTimeInterval(-100 * 86_400)
        )
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    @Test("Overdue, Upcoming, and Contact Detail all anchor a never-contacted contact on createdAt")
    func allThreeSurfacesAgreeOnNeverContactedAnchor() async throws {
        let contact = Self.neverContactedContact()
        let calendar = Self.utcCalendar

        // Overdue: the pure row-builder directly. 100 days since createdAt,
        // minus the 14-day cadence, is 86 days overdue.
        let overdueRow = try #require(OverdueViewModel.makeOverdueRow(
            for: contact,
            now: Self.now,
            calendar: calendar
        ))
        #expect(overdueRow.overdueDays == 86)

        // Contact Detail: the property this blocker fixed. Same calendar
        // and clock as Overdue above, so an exact match on `days` is a real
        // assertion, not a coincidence of rounding.
        let contacts = StubContactRepository([contact])
        let contactDetailVM = ContactDetailViewModel(
            contactId: contact.id,
            contacts: contacts,
            interactionsRepo: StubInteractionRepository(),
            scheduler: SchedulingPass(reminders: StubReminderRepository(), clock: { Self.now }),
            clock: { Self.now },
            calendar: calendar
        )
        await contactDetailVM.load()
        #expect(contactDetailVM.overdueSummary.isOverdue)
        #expect(contactDetailVM.overdueSummary.days == overdueRow.overdueDays)

        // Upcoming: the contact must appear, anchored on createdAt — an
        // anchor silently falling back to `now` would compute the next due
        // date as `now + 14d`, not resolve to "already due" at all.
        let window = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 23, minute: 59))],
            timezoneIdentifier: "UTC"
        )
        let reminders = StubReminderRepository()
        let upcomingVM = UpcomingViewModel(
            contacts: contacts,
            reminders: reminders,
            scheduler: SchedulingPass(reminders: reminders, clock: { Self.now }),
            interactions: StubInteractionRepository(),
            window: window,
            clock: { Self.now }
        )
        await upcomingVM.load()
        let upcomingRow = try #require(upcomingVM.groups.flatMap(\.rows).first { $0.contactId == contact.id })
        // 86 days overdue is already far past due, so the resolved slot is
        // "now" itself (the already-due branch) — not a future date that
        // would result from anchoring on `now` instead of `createdAt`.
        #expect(upcomingRow.scheduledFor == Self.now)
    }
}
