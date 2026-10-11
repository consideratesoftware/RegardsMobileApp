import Foundation
import Testing

/// R57 gate (TF-06). The reminder pipeline must not schedule notifications
/// until TF-07 resolves R57, because nothing yet reconciles pending
/// notifications with `ScheduledReminder` rows (a scheduled notification
/// would outlive a Caught up or an archive). The adapter in
/// `Platform/Notifications/` is the only code allowed to name the
/// notification center or build a request; everything else must stay silent.
///
/// This lives in the unit target so it runs in the required iOS CI job.
/// TF-07 deletes this file in the PR that resolves R57.
struct NotificationSchedulingGateTests {
    private static let forbiddenTokens = [".schedule(", "UNUserNotificationCenter", "UNNotificationRequest("]
    private static let adapterDirectory = "/Platform/Notifications/"

    /// `#filePath` is `<repo>/ios/RegardsTests/App/<this file>`.
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // RegardsTests
            .deletingLastPathComponent()  // ios
            .appendingPathComponent("Regards", isDirectory: true)
    }

    private static func swiftFiles() throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourceRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test("No app code outside the adapter schedules notifications until R57 is resolved")
    func noAppCodeOutsideAdapterSchedulesNotifications() throws {
        let scanned = try Self.swiftFiles().filter { !$0.path.contains(Self.adapterDirectory) }

        // Fails closed: a moved or renamed source tree must not leave a
        // scan of nothing that passes.
        #expect(scanned.count > 50, "scanned only \(scanned.count) files under \(Self.sourceRoot.path)")

        var violations: [String] = []
        for file in scanned {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbiddenTokens where text.contains(token) {
                violations.append("\(file.lastPathComponent) contains \(token)")
            }
        }
        #expect(
            violations.isEmpty,
            "R57 gate: only Platform/Notifications may schedule notifications until TF-07. \(violations)"
        )
    }

    @Test("The exempt adapter directory exists and still contains a forbidden token, so the scan is not vacuous")
    func adapterDirectoryIsExemptAndStillMatchesTheScan() throws {
        let adapterFiles = try Self.swiftFiles().filter { $0.path.contains(Self.adapterDirectory) }
        #expect(!adapterFiles.isEmpty, "no Swift files under Platform/Notifications")

        let adapterText = try adapterFiles
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        #expect(Self.forbiddenTokens.contains { adapterText.contains($0) })
    }
}
