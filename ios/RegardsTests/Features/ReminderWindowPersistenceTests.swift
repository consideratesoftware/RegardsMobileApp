import Foundation
import Testing
@testable import Regards

/// TF-05 slice 3: an edited window survives a relaunch, and the picker's
/// time-of-day conversion does not depend on the device zone.
///
/// Known limit of the conversion test: on a host whose zone is UTC, a
/// conversion through the local calendar gives the same instants, so that
/// mutation is indistinguishable there. It is caught on any other zone. TF-06
/// documented the same limit when it dropped `NSTimeZone.default` mutation.
///
/// `RegardsTabRoot.makeReminderWindowsViewModel(runtime:upcoming:)` returns the
/// global-target editor wired so `onSaved` calls `upcoming.updateWindow`.
@MainActor
struct ReminderWindowPersistenceTests {

    @Test("A saved window, horizon included, is what the next launch composes")
    func editedWindowSurvivesRelaunch() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("regards-window-relaunch-\(UUID().uuidString)", isDirectory: true)
        // Best-effort cleanup of the temp directory; a leftover file cannot affect another test.
        defer { try? fileManager.removeItem(at: root) }
        let fileName = "relaunch.sqlite"
        let stored = ReminderWindowEditorFixtures.storedGlobal

        let saved: ReminderWindow
        do {
            let environment = try ProductionRepositoryFactory.makeFileBackedEnvironment(
                applicationSupportDirectory: root, fileName: fileName, fileManager: fileManager
            )
            try await environment.window.saveGlobal(stored)
            let runtime = try await AppRuntime.makeProduction(environment: environment)
            let upcoming = RegardsTabRoot.makeUpcomingViewModel(runtime: runtime)
            let editor = RegardsTabRoot.makeReminderWindowsViewModel(runtime: runtime, upcoming: upcoming)
            await editor.load()
            editor.draft.digestHorizonDays = 7
            editor.draft.allowedDays = .saturday
            #expect(await editor.save())
            saved = try await environment.window.fetchGlobal()
        }

        // Only the edited fields changed.
        #expect(saved.digestHorizonDays == 7)
        #expect(saved.allowedDays == .saturday)
        #expect(saved.allowedTimeRanges == stored.allowedTimeRanges)
        #expect(saved.quietHours == stored.quietHours)
        #expect(saved.timezoneIdentifier == stored.timezoneIdentifier)
        #expect(saved.occasionTime == stored.occasionTime)

        let reopened = try ProductionRepositoryFactory.makeFileBackedEnvironment(
            applicationSupportDirectory: root, fileName: fileName, fileManager: fileManager
        )
        let runtime = try await AppRuntime.makeProduction(environment: reopened)
        #expect(runtime.window == saved)
        #expect(RegardsTabRoot.makeUpcomingViewModel(runtime: runtime).horizonDays == 7)
    }

    /// The picker works in a fixed reference date (2000-01-01 00:00 UTC, epoch
    /// 946_684_800), so no minute of the day is skipped or doubled by a zone's
    /// DST or odd offset. Each `pickerDate` is compared with the literal UTC
    /// instant, which catches a conversion through the local calendar on any
    /// non-UTC host. The device zone is not changed here: it is process-wide
    /// and other suites read `TimeZone.current`.
    @Test("Every minute of the day maps to its instant on the 2000-01-01 UTC reference and back")
    func timeOfDayDateRoundTripAllMinutes() {
        let referenceMidnightUTC: TimeInterval = 946_684_800
        for minutes in 0..<1_440 {
            let time = TimeOfDay(minutesSinceMidnight: minutes)
            let date = time.pickerDate
            #expect(
                date.timeIntervalSince1970 == referenceMidnightUTC + TimeInterval(minutes * 60),
                "minute \(minutes)"
            )
            #expect(TimeOfDay(pickerDate: date) == time, "minute \(minutes)")
        }
    }
}
