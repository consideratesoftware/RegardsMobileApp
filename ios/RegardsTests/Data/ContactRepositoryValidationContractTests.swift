import Testing
@testable import Regards

extension ContactRepositoryContractTests {
    @Test(
        "Contact writes reject invalid per-contact reminder windows",
        arguments: RepositoryContractBackend.allCases
    )
    func invalidReminderWindowOverrideIsRejected(
        backend: RepositoryContractBackend
    ) async throws {
        let repositories = try backend.makeRepositories()
        var contact = contractContact(
            id: try contractUUID(103),
            suffix: "invalid-window",
            tracked: true
        )
        contact.reminderWindowOverride = ReminderWindow(
            allowedDays: .allDays,
            allowedTimeRanges: [
                TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 11)),
            ],
            timezoneIdentifier: "Etc/UTC",
            digestHorizonDays: 8
        )

        await expectWriteRejected { try await repositories.contacts.upsert(contact) }
        #expect(try await repositories.contacts.fetch(id: contact.id) == nil)
    }
}
