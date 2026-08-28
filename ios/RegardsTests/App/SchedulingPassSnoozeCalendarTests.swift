import Foundation
import Testing
@testable import Regards

/// `SchedulingPass.snooze`'s calendar-boundary coverage, split out of
/// `SchedulingPassTests.swift` to keep that file under SwiftLint's 500-line
/// limit — the same reason `ContactObservationContractTests` was split from
/// `RepositoriesTests.swift`. Shares `RepositoriesTests.swift`'s
/// `RepositoryContractBackend` / `contractContact` / `contractUUID` helpers.
struct SchedulingPassSnoozeCalendarTests {

    /// A calendar pinned to a zone that definitely observes DST, for the
    /// same reason `SchedulingPassTests` pins its own: the machine running
    /// the test may sit in a zone with no transition at all.
    private static var losAngelesCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }

    /// Staged review round 13, coverage gap: both existing DST tests land on
    /// *valid* post-transition wall-clock times, so nothing exercised a
    /// target instant that does not exist at all. `snooze` falls back to
    /// `now.addingTimeInterval(7 * 86_400)` when
    /// `calendar.date(byAdding:value:to:)` returns `nil`, and that `??` had
    /// no test naming the situation it exists for.
    ///
    /// 2027-03-14 02:30 in America/Los_Angeles is skipped outright — the
    /// clock jumps 2:00 am → 3:00 am — so a snooze taken at 02:30 exactly a
    /// week earlier targets an instant with no local representation. What
    /// this pins is that the write still lands on a real instant one week
    /// later in elapsed terms, and specifically at 03:30 local: Foundation
    /// resolves a skipped wall-clock time forward past the gap rather than
    /// failing, which means the `??` fallback is *not* reached here. Worth a
    /// test precisely because that is the opposite of what the fallback's
    /// presence implies to a reader.
    @Test("Snooze targeting a wall-clock instant skipped by spring-forward still lands on a real instant")
    func snoozeTargetingSkippedWallClockInstantLandsOnRealInstant() async throws {
        let calendar = Self.losAngelesCalendar
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(522), suffix: "snooze-dst-gap", tracked: true)
        try await repositories.contacts.upsert(contact)
        // 2027-03-07 02:30 local — a valid instant; the same wall-clock time
        // one week later (2027-03-14 02:30) is the one that does not exist.
        let now = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 3, day: 7, hour: 2, minute: 30
        )))
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now },
            calendar: calendar
        )

        try await scheduler.snooze(contactId: contact.id)

        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        let landed = try #require(pending.first).scheduledFor
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: landed)
        #expect(components.year == 2027)
        #expect(components.month == 3)
        #expect(components.day == 14)
        // Pushed past the skipped hour, not into it.
        #expect(components.hour == 3)
        #expect(components.minute == 30)
    }

    /// Staged review round 13, coverage gap: the existing year-boundary test
    /// crosses Dec 28 → Jan 4 and never touches February, so no test proved
    /// the 7-day push counts Feb 29 in a leap year. 2028 is a leap year, so
    /// Feb 25 + 7 days is Mar 3 — a naive 28-day February would give Mar 4.
    @Test("Snooze across a leap-year February counts Feb 29")
    func snoozeAcrossLeapYearFebruaryCountsTheLeapDay() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Etc/UTC"))
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(523), suffix: "snooze-leap-day", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = try #require(calendar.date(from: DateComponents(
            year: 2028, month: 2, day: 25, hour: 8, minute: 0
        )))
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now },
            calendar: calendar
        )

        try await scheduler.snooze(contactId: contact.id)

        let expected = try #require(calendar.date(from: DateComponents(
            year: 2028, month: 3, day: 3, hour: 8, minute: 0
        )))
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending[0].scheduledFor == expected)
    }

    /// The non-leap half of the same gap: 2027 is not a leap year, so
    /// Feb 22 + 7 days is Mar 1, not Feb 29 (which does not exist) and not
    /// Mar 2 (which is what counting a 29-day February would give).
    @Test("Snooze across a non-leap February lands on March 1")
    func snoozeAcrossNonLeapFebruaryLandsOnMarchFirst() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Etc/UTC"))
        let repositories = try RepositoryContractBackend.mock.makeRepositories()
        let contact = contractContact(id: try contractUUID(524), suffix: "snooze-non-leap", tracked: true)
        try await repositories.contacts.upsert(contact)
        let now = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 2, day: 22, hour: 8, minute: 0
        )))
        let scheduler = SchedulingPass(
            reminders: repositories.reminders,
            contacts: repositories.contacts,
            clock: { now },
            calendar: calendar
        )

        try await scheduler.snooze(contactId: contact.id)

        let expected = try #require(calendar.date(from: DateComponents(
            year: 2027, month: 3, day: 1, hour: 8, minute: 0
        )))
        let pending = try await repositories.reminders.fetchPending(forContact: contact.id)
        #expect(pending[0].scheduledFor == expected)
    }
}
