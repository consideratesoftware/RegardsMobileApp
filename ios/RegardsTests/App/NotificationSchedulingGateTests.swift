import Foundation
import Testing

/// R57 gate (TF-06). Nothing in the app may deliver a notification until
/// TF-07 resolves R57. The reason is a timing one: `SchedulingPass.snooze`
/// writes a raw `now + 7d` to `pendingSnoozeDate`, so a notification built
/// from that row would fire at an instant outside the user's reminder window
/// (§9).
///
/// The first line of defense is the compiler: `NotificationScheduling` has no
/// scheduling member, so no caller can schedule through it. This test covers
/// the routes the compiler doesn't, with three rules matched after stripping
/// comments:
/// 1. Outside the adapter file, no `UNUserNotificationCenter`,
///    `UILocalNotification`, or `scheduleLocalNotification`.
/// 2. Inside the adapter file, no `add` as a whole word. Every route to a
///    delivered notification ends at the center's `add`, and rule 1 confines
///    the center to the adapter.
/// 3. Outside the adapter file, no `ReminderNotificationRequest`, so nothing
///    builds a request from a row.
///
/// The adapter is exempt by exact relative-path equality (symlinks resolved on
/// both sides), not by a directory-name substring.
///
/// Known limits. The gate catches accidental wiring; selector strings,
/// reflection, or a typealias that leaks the center are review's job. A `//`
/// inside a string literal hides the rest of that line from the scan. A string
/// literal that contains a banned word fails the test, which is the safe
/// direction.
///
/// This lives in the unit target so it runs in the required iOS CI job.
/// TF-07 deletes this file in the PR that resolves R57.
struct NotificationSchedulingGateTests {
    private static let adapterRelativePath = "Platform/Notifications/NotificationScheduling.swift"

    private static let centerPattern = #"\b(UNUserNotificationCenter|UILocalNotification|scheduleLocalNotification)\b"#
    private static let addPattern = #"\badd\b"#
    private static let requestPattern = #"\bReminderNotificationRequest\b"#
    private static let commentPattern = #"//[^\n]*|/\*[\s\S]*?\*/"#

    /// `#filePath` is `<repo>/ios/RegardsTests/App/<this file>`.
    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // RegardsTests
            .deletingLastPathComponent()  // ios
            .appendingPathComponent("Regards", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    /// Every Swift file under `sourceRoot`, as (path relative to the root, text).
    private static func sources() throws -> [(path: String, text: String)] {
        let root = sourceRoot
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))
        let prefix = root.path + "/"
        return try enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .map { url in
                let resolved = url.resolvingSymlinksInPath().path
                let relative = resolved.hasPrefix(prefix) ? String(resolved.dropFirst(prefix.count)) : resolved
                return (relative, try String(contentsOf: url, encoding: .utf8))
            }
    }

    private static func strippingComments(_ text: String) -> String {
        text.replacingOccurrences(of: commentPattern, with: " ", options: .regularExpression)
    }

    /// The gate's matcher. Returns the rules the source breaks.
    private static func violations(in text: String, isAdapter: Bool) -> [String] {
        let code = strippingComments(text)
        func hits(_ pattern: String) -> Bool { code.range(of: pattern, options: .regularExpression) != nil }
        var broken: [String] = []
        if isAdapter {
            if hits(addPattern) { broken.append("adapter calls add") }
        } else {
            if hits(centerPattern) { broken.append("names the notification center") }
            if hits(requestPattern) { broken.append("names ReminderNotificationRequest") }
        }
        return broken
    }

    @Test("Only the adapter names the notification center or builds requests, and the adapter never calls add")
    func noAppCodeReachesTheNotificationCenterUntilR57IsResolved() throws {
        let files = try Self.sources()

        // Fails closed: a moved or renamed source tree must not leave a scan
        // of nothing that passes, and the exemption must name a real file.
        #expect(files.count > 50, "scanned only \(files.count) files under \(Self.sourceRoot.path)")
        #expect(files.contains { $0.path == Self.adapterRelativePath }, "no file at \(Self.adapterRelativePath)")

        let failures = files.flatMap { file in
            Self.violations(in: file.text, isAdapter: file.path == Self.adapterRelativePath)
                .map { "\(file.path) \($0)" }
        }
        #expect(
            failures.isEmpty,
            "R57 gate: nothing may deliver notifications until TF-07 resolves R57. \(failures)"
        )
    }

    @Test("The gate patterns catch odd spacing and backticks and ignore comments")
    func gatePatternsCatchSpacingBackticksAndIgnoreComments() {
        let adapterMatches = ["center.add (r)", "center.`add`(r)", "let f = center.add"]
        let appMatches = [
            "`UNUserNotificationCenter`", "UNUserNotificationCenter .current()",
            "let r = ReminderNotificationRequest(identifier: id)",
        ]
        let adapterIgnores = ["/* add */", "address", "addingTimeInterval"]
        let appIgnores = ["// UNUserNotificationCenter", "/// ReminderNotificationRequest"]

        for text in adapterMatches {
            #expect(!Self.violations(in: text, isAdapter: true).isEmpty, "should match: \(text)")
        }
        for text in appMatches {
            #expect(!Self.violations(in: text, isAdapter: false).isEmpty, "should match: \(text)")
        }
        for text in adapterIgnores {
            #expect(Self.violations(in: text, isAdapter: true).isEmpty, "should not match: \(text)")
        }
        for text in appIgnores {
            #expect(Self.violations(in: text, isAdapter: false).isEmpty, "should not match: \(text)")
        }
    }
}
