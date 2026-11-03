import Foundation
import Testing
@testable import Regards

/// Occasion rows and the cadence/occasion same-day rule (TF-07c, §9 contracts
/// 4 and 6, R5, owner ruling 9). Dates are New York local times
/// (`PassFixture`); occasions fire at the global window's occasion time,
/// 09:00 unless a test says otherwise.
struct SchedulingPassOccasionTests {

    /// Birthdays on 06-12 for the given contact numbers.
    private static func birthdays(on monthDay: MonthDay = MonthDay(month: 6, day: 12), for numbers: [Int]) throws
        -> @Sendable ([Contact]) async -> [ContactOccasion] {
        let ids = try numbers.map { try contractUUID(7_000 + $0) }
        return { contacts in
            contacts.filter { ids.contains($0.id) }
                .map { ContactOccasion(contactId: $0.id, kind: .birthday, monthDay: monthDay, label: "Birthday") }
        }
    }

    private static let quietEvenings = TimeRange(
        start: TimeOfDay(hour: 22, minute: 30), end: TimeOfDay(hour: 7, minute: 30))

    // MARK: - Contract 6

    /// Overdue on 06-12 at 10:00, so the cadence slot is 06-12 18:00, the same
    /// local day as the birthday. The occasion wins the day.
    @Test(
        "A cadence slot on a contact's occasion day moves to the next day's slot",
        arguments: RepositoryContractBackend.allCases
    )
    func sameDayOccasionDefersCadence(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, occasions: try Self.birthdays(for: [1]))
        let withBirthday = try await fixture.addContact(1, cadenceDays: 10, lastInteracted: "2026-06-02 10:00")
        let withoutBirthday = try await fixture.addContact(2, cadenceDays: 10, lastInteracted: "2026-06-02 10:00")

        try await fixture.pass.runFull()

        #expect(try await fixture.cadenceRow(withoutBirthday)?.scheduledFor == PassFixture.at("2026-06-12 18:00"))
        #expect(try await fixture.cadenceRow(withBirthday)?.scheduledFor == PassFixture.at("2026-06-13 18:00"))
        #expect(try await fixture.occasionRow(withBirthday, .birthday)?.scheduledFor
                == PassFixture.at("2026-06-12 09:00"))
    }

    /// Quiet hours 08:00 to 07:00 next day swallow the 09:00 occasion, so it
    /// never notifies. Contract 6 defers a cadence reminder only to an
    /// occasion that will notify, so the 07:00 slot that day stands. The
    /// occasion's row stays (owner ruling 9).
    @Test(
        "A cadence slot is not moved for an occasion that will never notify",
        arguments: RepositoryContractBackend.allCases
    )
    func neverNotifyingOccasionDoesNotDeferCadence(backend: RepositoryContractBackend) async throws {
        let override = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 7), end: TimeOfDay(hour: 8))],
            quietHours: TimeRange(start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 7)),
            timezoneIdentifier: PassFixture.zone)
        let fixture = try await PassFixture(
            backend: backend, occasions: try Self.birthdays(on: MonthDay(month: 6, day: 11), for: [1]))
        // Due 06-11 06:00, so the first slot is 07:00 on the occasion's day.
        let contact = try await fixture.addContact(
            1, cadenceDays: 10, lastInteracted: "2026-06-01 06:00", override: override)

        try await fixture.pass.runFull()

        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == PassFixture.at("2026-06-11 07:00"))
        #expect(try await fixture.occasionRow(contact, .birthday)?.scheduledFor == PassFixture.at("2026-06-11 09:00"))
    }

    /// Snooze resolves through the same derivation as the run, so a snooze
    /// whose slot lands on the contact's occasion day moves past it too.
    @Test(
        "A snooze landing on an occasion day moves to the next day's slot",
        arguments: RepositoryContractBackend.allCases
    )
    func snoozeLandingOnAnOccasionDayMovesToTheNextDaySlot(backend: RepositoryContractBackend) async throws {
        // Snoozed on 06-10, the floor is 06-17 10:00 and its slot 06-17 18:00.
        let fixture = try await PassFixture(
            backend: backend, occasions: try Self.birthdays(on: MonthDay(month: 6, day: 17), for: [1]))
        let withBirthday = try await fixture.addContact(1)
        let withoutBirthday = try await fixture.addContact(2)

        _ = try await fixture.pass.snooze(contactId: withBirthday.id)
        _ = try await fixture.pass.snooze(contactId: withoutBirthday.id)

        let moved = try #require(try await fixture.cadenceRow(withBirthday))
        #expect(moved.snoozedUntil == PassFixture.at("2026-06-17 10:00"))
        #expect(moved.scheduledFor == PassFixture.at("2026-06-18 18:00"))
        #expect(try await fixture.cadenceRow(withoutBirthday)?.scheduledFor == PassFixture.at("2026-06-17 18:00"))

        try await fixture.pass.runFull()

        #expect(try await fixture.cadenceRow(withBirthday) == moved, "the next run keeps the deferred slot")
    }

    /// The slot after an occasion day can be another occasion day (here a
    /// birthday on 06-12 and an anniversary on 06-13), so the deferral repeats.
    @Test("Consecutive occasion days defer the cadence slot twice", arguments: RepositoryContractBackend.allCases)
    func consecutiveOccasionDaysDeferCadenceTwice(backend: RepositoryContractBackend) async throws {
        let id = try contractUUID(7_001)
        let fixture = try await PassFixture(backend: backend, occasions: { _ in
            [ContactOccasion(contactId: id, kind: .birthday, monthDay: MonthDay(month: 6, day: 12)),
             ContactOccasion(contactId: id, kind: .anniversary, monthDay: MonthDay(month: 6, day: 13))]
        })
        // Due 06-12 10:00, so the first slot is 06-12 18:00.
        let contact = try await fixture.addContact(1, cadenceDays: 10, lastInteracted: "2026-06-02 10:00")

        try await fixture.pass.runFull()

        #expect(try await fixture.cadenceRow(contact)?.scheduledFor == PassFixture.at("2026-06-14 18:00"))
    }

    // MARK: - Quiet hours and occasion time (R5)

    /// The birthday sits at 09:00. The override's quiet hours 06:00-10:00
    /// move it to 10:00; the global window has no quiet hours, so a pass that
    /// used the global window would leave it at 09:00.
    @Test("An occasion uses the contact's override quiet hours", arguments: RepositoryContractBackend.allCases)
    func occasionQuietHoursUseOverride(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, occasions: try Self.birthdays(for: [1, 2]))
        let overridden = try await fixture.addContact(
            1, override: PassFixture.eveningWindow(
                quiet: TimeRange(start: TimeOfDay(hour: 6), end: TimeOfDay(hour: 10))))
        let global = try await fixture.addContact(2)

        try await fixture.pass.runFull()

        #expect(try await fixture.occasionRow(overridden, .birthday)?.scheduledFor
                == PassFixture.at("2026-06-12 10:00"))
        #expect(try await fixture.occasionRow(global, .birthday)?.scheduledFor
                == PassFixture.at("2026-06-12 09:00"))
    }

    @Test(
        "An override with no quiet hours ignores the global quiet hours",
        arguments: RepositoryContractBackend.allCases
    )
    func occasionIgnoresGlobalQuietHoursWhenOverrideHasNone(backend: RepositoryContractBackend) async throws {
        let globalQuiet = TimeRange(start: TimeOfDay(hour: 8), end: TimeOfDay(hour: 10))
        let fixture = try await PassFixture(
            backend: backend, window: PassFixture.eveningWindow(quiet: globalQuiet),
            occasions: try Self.birthdays(for: [1, 2]))
        let overridden = try await fixture.addContact(1, override: PassFixture.eveningWindow())
        let global = try await fixture.addContact(2)

        try await fixture.pass.runFull()

        #expect(try await fixture.occasionRow(overridden, .birthday)?.scheduledFor
                == PassFixture.at("2026-06-12 09:00"))
        #expect(try await fixture.occasionRow(global, .birthday)?.scheduledFor
                == PassFixture.at("2026-06-12 10:00"))
    }

    /// The override was saved when the occasion time was 09:00 and still holds
    /// that copy. The global time is 08:00 now, inside the override's quiet
    /// hours 06:00-08:30, so the row is 08:30; reading the stale 09:00 copy
    /// would leave it at 09:00.
    @Test(
        "An occasion's time comes from the global window, never the override's copy",
        arguments: RepositoryContractBackend.allCases
    )
    func occasionTimeComesFromTheGlobalWindow(backend: RepositoryContractBackend) async throws {
        let staleOverride = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 18), end: TimeOfDay(hour: 19))],
            quietHours: TimeRange(start: TimeOfDay(hour: 6), end: TimeOfDay(hour: 8, minute: 30)),
            timezoneIdentifier: PassFixture.zone,
            occasionTime: TimeOfDay(hour: 9))
        let fixture = try await PassFixture(
            backend: backend,
            window: PassFixture.eveningWindow(occasionTime: TimeOfDay(hour: 8)),
            occasions: try Self.birthdays(for: [1]))
        let contact = try await fixture.addContact(1, override: staleOverride)

        try await fixture.pass.runFull()

        #expect(try await fixture.occasionRow(contact, .birthday)?.scheduledFor == PassFixture.at("2026-06-12 08:30"))
    }

    /// Owner ruling 9: quiet hours 22:30-07:30 run past a 23:00 occurrence's
    /// day, so no notification time exists. The row stays at the occurrence so
    /// Upcoming still shows the occasion.
    @Test(
        "An occasion whose quiet hours run past its day keeps its row at the occurrence",
        arguments: RepositoryContractBackend.allCases
    )
    func neverNotifyingOccasionKeepsItsRow(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(
            backend: backend,
            window: PassFixture.eveningWindow(quiet: Self.quietEvenings, occasionTime: TimeOfDay(hour: 23)),
            occasions: try Self.birthdays(for: [1]))
        let contact = try await fixture.addContact(1)

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(row.scheduledFor == PassFixture.at("2026-06-12 23:00"))
        #expect(row.state == .pending)
    }

    // MARK: - Row shape and moving clocks

    @Test(
        "An occasion row carries its identity, month-day, label and notification id",
        arguments: RepositoryContractBackend.allCases
    )
    func occasionRowCarriesItsIdentity(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(backend: backend, occasions: try Self.birthdays(for: [1]))
        let contact = try await fixture.addContact(1)

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(row.id == SchedulingPass.reminderID(contactId: contact.id, kind: .birthday))
        #expect(row.occasionDate == "06-12")
        #expect(row.occasionLabel == "Birthday")
        #expect(row.osNotificationId == "contact-\(contact.id.uuidString)-birthday")
        #expect(row.id != fixture.cadenceID(contact))
    }

    @Test(
        "Two birthdays for one contact leave one row, for the nearer date",
        arguments: RepositoryContractBackend.allCases
    )
    func nearestOccurrenceWinsPerKind(backend: RepositoryContractBackend) async throws {
        let id = try contractUUID(7_001)
        let fixture = try await PassFixture(backend: backend, occasions: { _ in
            [ContactOccasion(contactId: id, kind: .birthday, monthDay: MonthDay(month: 6, day: 20)),
             ContactOccasion(contactId: id, kind: .birthday, monthDay: MonthDay(month: 6, day: 12))]
        })
        let contact = try await fixture.addContact(1)

        try await fixture.pass.runFull()

        let rows = try await fixture.repositories.reminders.fetchPending(forContact: contact.id)
            .filter { $0.kind == .birthday }
        #expect(rows.map(\.scheduledFor) == [PassFixture.at("2026-06-12 09:00")])
    }

    /// Installing at noon on the birthday gives "fire now" (R5): the
    /// occurrence is `now`. A later run must not chase the clock.
    @Test(
        "A same-day occasion that already fired stays put on a later run",
        arguments: RepositoryContractBackend.allCases
    )
    func sameDayLateOccasionStaysPutOnALaterRun(backend: RepositoryContractBackend) async throws {
        let fixture = try await PassFixture(
            backend: backend, now: "2026-06-10 12:00",
            occasions: try Self.birthdays(on: MonthDay(month: 6, day: 10), for: [1]))
        let contact = try await fixture.addContact(1, cadenceDays: 30, lastInteracted: "2026-06-09 10:00")
        try await fixture.pass.runFull()
        let first = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(first.scheduledFor == PassFixture.at("2026-06-10 12:00"))
        let writesBefore = await fixture.reminders.writeCount

        fixture.setNow("2026-06-10 13:00")
        try await fixture.pass.runFull()

        #expect(try await fixture.occasionRow(contact, .birthday) == first)
        #expect(await fixture.reminders.writeCount == writesBefore)
    }

    // MARK: - Same-date tie-breaks

    /// Two same-kind occasions for one contact that land on one instant. The
    /// row the run writes must not depend on the order the source returns them
    /// in (Contacts has no stable order), so a second run in the other order
    /// writes nothing.
    private static func tiedOccasions(
        _ entries: [(monthDay: MonthDay, label: String?)]
    ) throws -> @Sendable ([Contact]) async -> [ContactOccasion] {
        let id = try contractUUID(7_001)
        return { _ in
            entries.map { ContactOccasion(contactId: id, kind: .birthday, monthDay: $0.monthDay, label: $0.label) }
        }
    }

    /// A pass over `fixture`'s repositories, sharing its counting wrapper and
    /// clock, that reads its occasions from `occasions`.
    private static func pass(
        over fixture: PassFixture,
        occasions: @escaping @Sendable ([Contact]) async -> [ContactOccasion]
    ) -> SchedulingPass {
        let clock = fixture.clock
        return SchedulingPass(
            reminders: fixture.reminders,
            contacts: fixture.repositories.contacts,
            interactions: fixture.repositories.interactions,
            window: fixture.repositories.window,
            occasions: occasions,
            clock: { clock.now() })
    }

    struct LabelOrder: Sendable, CustomTestStringConvertible {
        let name: String
        let first: String?
        let second: String?
        /// What the row stores, the same for both orders.
        let stored: String?

        var testDescription: String { name }
    }

    static let labelOrders = [
        LabelOrder(name: "A then B", first: "A", second: "B", stored: "A"),
        LabelOrder(name: "B then A", first: "B", second: "A", stored: "A"),
        LabelOrder(name: "nil then empty", first: nil, second: "", stored: nil),
        LabelOrder(name: "empty then nil", first: "", second: nil, stored: nil),
    ]

    @Test(
        "Two same-date occasions of a kind write the same row whatever order the source returns them in",
        arguments: RepositoryContractBackend.allCases, labelOrders
    )
    func sameDateOccasionsWriteTheSameRowInEitherOrder(
        backend: RepositoryContractBackend, order: LabelOrder
    ) async throws {
        let day = MonthDay(month: 6, day: 12)
        let fixture = try await PassFixture(
            backend: backend,
            occasions: try Self.tiedOccasions([(day, order.first), (day, order.second)]))
        let contact = try await fixture.addContact(1)

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(row.occasionLabel == order.stored)
    }

    @Test(
        "Reversing the order the source returns same-date occasions in writes nothing",
        arguments: RepositoryContractBackend.allCases, labelOrders
    )
    func reversingTheSourceOrderWritesNothing(backend: RepositoryContractBackend, order: LabelOrder) async throws {
        let day = MonthDay(month: 6, day: 12)
        let fixture = try await PassFixture(
            backend: backend,
            occasions: try Self.tiedOccasions([(day, order.first), (day, order.second)]))
        let contact = try await fixture.addContact(1)
        try await fixture.pass.runFull()
        let written = try #require(try await fixture.occasionRow(contact, .birthday))
        let writesBefore = await fixture.reminders.writeCount
        let reversed = Self.pass(
            over: fixture, occasions: try Self.tiedOccasions([(day, order.second), (day, order.first)]))

        try await reversed.runFull()

        #expect(try await fixture.occasionRow(contact, .birthday) == written)
        #expect(await fixture.reminders.writeCount == writesBefore)
    }

    /// In a non-leap year (2027) Feb 29 falls back to Feb 28, so both resolve
    /// to the same instant. The month-day breaks the tie, and "02-28" wins.
    @Test(
        "Feb 29 and Feb 28 in a non-leap year write the Feb 28 row in either order",
        arguments: RepositoryContractBackend.allCases, [true, false]
    )
    func feb29AndFeb28CollideOnFeb28(backend: RepositoryContractBackend, leapDayFirst: Bool) async throws {
        let feb28 = MonthDay(month: 2, day: 28)
        let feb29 = MonthDay(month: 2, day: 29)
        let entries: [(monthDay: MonthDay, label: String?)] = leapDayFirst
            ? [(feb29, "Leap"), (feb28, "Common")]
            : [(feb28, "Common"), (feb29, "Leap")]
        let fixture = try await PassFixture(backend: backend, occasions: try Self.tiedOccasions(entries))
        let contact = try await fixture.addContact(1)

        try await fixture.pass.runFull()

        let row = try #require(try await fixture.occasionRow(contact, .birthday))
        #expect(row.occasionDate == "02-28")
        #expect(row.occasionLabel == "Common")
        #expect(row.scheduledFor == PassFixture.at("2027-02-28 09:00"))
    }
}
