import Foundation
import Testing
@testable import Regards

/// The `ContactRepository.updateReminderWindowOverride` protocol-extension
/// fallback that in-memory fakes (like `StubContactRepository`) run: validate,
/// fetch, refuse an inactive contact, upsert. GRDB and the mock override it
/// with a field-scoped write, covered in `ReminderWindowOverrideContractTests`.
struct ContactRepositoryOverrideFallbackTests {

    private static let window = ReminderWindow(
        allowedDays: .saturday,
        allowedTimeRanges: [TimeRange(start: TimeOfDay(hour: 10), end: TimeOfDay(hour: 12))],
        timezoneIdentifier: "Etc/UTC"
    )

    private static func contact(_ suffix: String, archivedAt: Date? = nil) -> Contact {
        Contact(
            systemContactRef: "fallback-\(suffix)",
            displayName: "Fallback \(suffix)",
            tracked: true,
            cadenceDays: 14,
            archivedAt: archivedAt
        )
    }

    @Test("The fallback stores the window for an active contact and a nil clears it")
    func successPathStoresAndClears() async throws {
        let target = Self.contact("success")
        let other = Self.contact("other")
        let repository = StubContactRepository([target, other])

        let stored = try await repository.updateReminderWindowOverride(id: target.id, window: Self.window)

        #expect(stored)
        #expect(try await repository.fetch(id: target.id)?.reminderWindowOverride == Self.window)
        #expect(try await repository.fetch(id: other.id) == other)

        let cleared = try await repository.updateReminderWindowOverride(id: target.id, window: nil)

        #expect(cleared)
        #expect(try await repository.fetch(id: target.id)?.reminderWindowOverride == nil)
    }

    /// Every read on this stub throws. An invalid window must fail with its
    /// own validation error, which only happens if validation runs before
    /// the fetch.
    @Test("The fallback validates before it reads anything")
    func invalidWindowThrowsBeforeTheFetch() async throws {
        let wrapping = TimeRange(start: TimeOfDay(hour: 22), end: TimeOfDay(hour: 1))
        let invalid = ReminderWindow(
            allowedDays: .allDays, allowedTimeRanges: [wrapping], timezoneIdentifier: "Etc/UTC"
        )
        let repository = StubContactRepository.failing([Self.contact("validate-first")])

        await #expect(throws: ReminderWindow.ValidationError.wrappingAllowedRange(wrapping)) {
            try await repository.updateReminderWindowOverride(id: UUID(), window: invalid)
        }
    }

    @Test("The fallback reports false and writes nothing for an archived or missing contact")
    func inactiveContactReturnsFalse() async throws {
        let archived = Self.contact("archived", archivedAt: Date(timeIntervalSince1970: 1_799_999_000))
        let repository = StubContactRepository([archived])

        let archivedResult = try await repository.updateReminderWindowOverride(id: archived.id, window: Self.window)
        let missingResult = try await repository.updateReminderWindowOverride(id: UUID(), window: Self.window)

        #expect(!archivedResult)
        #expect(!missingResult)
        #expect(try await repository.fetch(id: archived.id) == archived)
    }
}
