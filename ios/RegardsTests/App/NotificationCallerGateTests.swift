import Foundation
import Testing

/// R57 gate (ARCHITECTURE.md §19), reduced. TF-06 must not ship notification
/// scheduling until R57 is resolved, and slice 4 is the slice that wires the
/// first production caller. Until then it checks 2 things:
/// - No file may call `schedule`, `cancel` or `pendingRequests` on a
///   `NotificationScheduling`, except the adapter's own folder and the fakes'
///   parity tests. The 2 fakes only define the members, so they need no
///   exemption. This scans `ios/Regards` and `ios/RegardsTests`.
/// - No file in `ios/Regards` outside `Platform/Notifications/` may name
///   `UNUserNotificationCenter`. The tests may: a doc comment and the
///   delegate selector in `UserNotificationsAdapterRequestTests` name it.
///
/// It scans raw source text, comments included, so it catches accidental
/// wiring only. It can't see 2 shapes: an implicit-self `schedule(...)` inside
/// a conformer or extension (no leading dot), and a method reference with no
/// parentheses, such as `let add = notifications.schedule`. Code review
/// catches those and deliberate evasion. Slice 4 deletes this file in the PR
/// that resolves R57.
struct NotificationCallerGateTests {
    /// `.schedule(`, `.cancel(identifiers:` and `.pendingRequests(`. The
    /// leading dot skips the members' own declarations, and the `identifiers:`
    /// label skips `Task.cancel()`.
    private static let callPattern = #"\.(schedule\s*\(|cancel\s*\(\s*identifiers:|pendingRequests\s*\()"#

    private static let centerPattern = #"\bUNUserNotificationCenter\b"#

    private static let adapterFolder = "Regards/Platform/Notifications/"

    private static func makesACall(_ text: String) -> Bool {
        text.range(of: callPattern, options: .regularExpression) != nil
    }

    private static let adapterPath = "Regards/Platform/Notifications/NotificationScheduling.swift"

    /// Paths relative to `ios/` that may make these calls.
    private static func mayCall(_ path: String) -> Bool {
        path.hasPrefix(adapterFolder) || [
            "RegardsTests/Platform/NotificationFakeParityTests.swift",
            "RegardsTests/App/NotificationCallerGateTests.swift",
        ].contains(path)
    }

    /// `#filePath` is `<repo>/ios/RegardsTests/App/<this file>`.
    private static var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // App
            .deletingLastPathComponent()  // RegardsTests
            .deletingLastPathComponent()  // ios
            .resolvingSymlinksInPath()
    }

    /// Every Swift file under `ios/Regards` and `ios/RegardsTests`, as (path
    /// relative to `ios/`, text).
    private static func sources() throws -> [(path: String, text: String)] {
        let prefix = iosRoot.path + "/"
        return try ["Regards", "RegardsTests"].flatMap { folder -> [(path: String, text: String)] in
            let enumerator = try #require(FileManager.default.enumerator(
                at: iosRoot.appendingPathComponent(folder, isDirectory: true),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))
            return try enumerator.compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .map { url in
                    let resolved = url.resolvingSymlinksInPath().path
                    let relative = resolved.hasPrefix(prefix) ? String(resolved.dropFirst(prefix.count)) : resolved
                    return (relative, try String(contentsOf: url, encoding: .utf8))
                }
        }
    }

    @Test("Only the adapter folder names the center, and only it and the fake tests call the scheduling members")
    func schedulingCallsAndTheCenterStayInsideTheAdapterFolder() throws {
        let files = try Self.sources()
        // Fail closed: a wrong root or a moved adapter must not read as a pass.
        #expect(files.count > 50, "scanned only \(files.count) files under \(Self.iosRoot.path)")
        #expect(files.contains { $0.path == Self.adapterPath }, "no file at \(Self.adapterPath)")

        let offenders = files
            .filter { !Self.mayCall($0.path) }
            .filter { Self.makesACall($0.text) }
            .map(\.path)

        #expect(offenders.isEmpty, "R57 gate: only the adapter and the fakes may call these members: \(offenders)")

        let centerNamers = files
            .filter { $0.path.hasPrefix("Regards/") && !$0.path.hasPrefix(Self.adapterFolder) }
            .filter { $0.text.range(of: Self.centerPattern, options: .regularExpression) != nil }
            .map(\.path)

        #expect(centerNamers.isEmpty, "R57 gate: only the adapter folder may name the center: \(centerNamers)")
    }

    /// Positive control: a pattern that matches nothing would pass the test
    /// above for every file.
    @Test("The patterns match the fake tests' calls, a call split across lines, and the center")
    func patternsMatchRealAndMultiLineCalls() throws {
        let parity = try #require(
            Self.sources().first { $0.path == "RegardsTests/Platform/NotificationFakeParityTests.swift" }
        )
        #expect(Self.makesACall(parity.text))
        #expect(Self.makesACall("await notifications.cancel(\n    identifiers: ids)"))
        let center = "let c = UNUserNotificationCenter.current()"
        #expect(center.range(of: Self.centerPattern, options: .regularExpression) != nil)
    }
}
