import Foundation
import Testing

/// R57 gate (ARCHITECTURE.md §19), reduced. TF-06 must not ship notification
/// scheduling until R57 is resolved, and slice 4 is the slice that wires the
/// first production caller. Until then no file may call `schedule`, `cancel`
/// or `pendingRequests` on a `NotificationScheduling`, except the adapter's own
/// folder, the 2 fakes, and the fakes' parity tests. A new call anywhere else
/// fails here.
///
/// It scans raw source text, comments included, so it catches accidental
/// wiring only. Code review catches deliberate evasion. Slice 4 deletes this
/// file in the PR that resolves R57.
struct NotificationCallerGateTests {
    /// `.schedule(`, `.cancel(identifiers:` and `.pendingRequests(`. The
    /// leading dot skips the members' own declarations and `Task.cancel()`.
    private static let callPattern = #"\.(schedule\s*\(|cancel\s*\(\s*identifiers:|pendingRequests\s*\()"#

    private static let adapterPath = "Regards/Platform/Notifications/NotificationScheduling.swift"

    /// Paths relative to `ios/` that may make these calls.
    private static func mayCall(_ path: String) -> Bool {
        path.hasPrefix("Regards/Platform/Notifications/") || [
            "RegardsTests/Support/ScriptedNotifications.swift",
            "Regards/App/AppLaunchCoordinator+DebugLaunch.swift",
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

    @Test("No file outside the adapter folder and the fakes calls schedule, cancel or pendingRequests")
    func onlyTheAdapterAndFakesCallTheSchedulingMembers() throws {
        let files = try Self.sources()
        // Fail closed: a wrong root or a moved adapter must not read as a pass.
        #expect(files.count > 50, "scanned only \(files.count) files under \(Self.iosRoot.path)")
        #expect(files.contains { $0.path == Self.adapterPath }, "no file at \(Self.adapterPath)")

        let pattern = try NSRegularExpression(pattern: Self.callPattern)
        let offenders = files
            .filter { !Self.mayCall($0.path) }
            .filter { pattern.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }
            .map(\.path)

        #expect(offenders.isEmpty, "R57 gate: only the adapter and the fakes may call these members: \(offenders)")
    }
}
