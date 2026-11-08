import Foundation
import Testing

/// R57 gate (ARCHITECTURE.md §19), reduced. TF-06 must not ship notification
/// scheduling until R57 is resolved, and slice 4 is the slice that wires the
/// first production caller. Until then it checks 3 things:
/// - No file may call `schedule`, `cancel` or `pendingRequests` on a
///   `NotificationScheduling`, except the adapter's own folder, the fakes'
///   parity tests and the gate itself. The 2 fakes only define the members, so
///   they need no exemption. This scans `ios/Regards` and `ios/RegardsTests`.
/// - No file in `ios/Regards` except `Platform/Notifications/NotificationScheduling.swift`
///   may name `UNUserNotificationCenter` (G1). The tests may: a doc comment and
///   the delegate selector in `UserNotificationsAdapterRequestTests` name it.
/// - No file in `ios/Regards` outside `Platform/Notifications/` may name
///   `UNNotificationRequest` or a `UN...NotificationTrigger` type such as
///   `UNCalendarNotificationTrigger` (G4). The tests may: the adapter request
///   tests build and read them.
///
/// G1 and G4 are kept from the deleted `NotificationSchedulingGateTests`. G1 is
/// kept as before: only `NotificationScheduling.swift` may name the center. G4
/// is narrowed from "the whole tree" to the adapter folder. G2 ("the
/// adapter never calls `add`") and G3 ("the adapter names the center exactly
/// 4 times") retire on purpose: TF-07e3 adds `schedule`, which calls `add`,
/// and the scheduling members.
///
/// It scans raw source text, comments included, so it catches accidental
/// wiring only. It can't see 3 shapes:
/// - an implicit-self `schedule(...)` inside a conformer or extension (no
///   leading dot);
/// - a method reference with no parentheses, such as
///   `let add = notifications.schedule`;
/// - request building that never spells a request or trigger type (G4 matches
///   type names only). `DebugNotificationScheduling.schedule` in
///   `AppLaunchCoordinator+DebugLaunch.swift` builds real requests outside the
///   adapter folder this way, through `UserNotificationsAdapter.makeRequest`
///   and `decode`.
///
/// Code review catches those and deliberate evasion. Slice 4 deletes this file
/// in the PR that resolves R57.
struct NotificationCallerGateTests {
    // MARK: - Patterns and allowed paths

    /// `.schedule(`, `.cancel(identifiers:` and `.pendingRequests(`. The
    /// leading dot skips the members' own declarations, and the `identifiers:`
    /// label skips `Task.cancel()`.
    private static let callPattern = #"\.(schedule\s*\(|cancel\s*\(\s*identifiers:|pendingRequests\s*\()"#

    private static let centerPattern = #"\bUNUserNotificationCenter\b"#

    /// G4: the request type and every trigger type (`UNCalendarNotificationTrigger`,
    /// `UNTimeIntervalNotificationTrigger`, `UNLocationNotificationTrigger`).
    private static let requestBuildingPattern = #"\bUNNotificationRequest\b|\bUN\w*NotificationTrigger\b"#

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

    // MARK: - Reading the sources

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

    // MARK: - Callers and the center

    @Test("Only the adapter file names the center; only the adapter folder, fake tests and gate call the members")
    func onlyTheAdapterFileNamesTheCenterAndOnlyAllowedFilesCall() throws {
        let files = try Self.sources()
        // Fail closed: a wrong root or a moved adapter must not read as a pass.
        #expect(files.count > 50, "scanned only \(files.count) files under \(Self.iosRoot.path)")
        #expect(files.contains { $0.path == Self.adapterPath }, "no file at \(Self.adapterPath)")

        let offenders = files
            .filter { !Self.mayCall($0.path) }
            .filter { Self.makesACall($0.text) }
            .map(\.path)

        #expect(
            offenders.isEmpty,
            "R57 gate: only the adapter, the fake tests and the gate may call these members: \(offenders)"
        )

        let centerNamers = files
            .filter { $0.path.hasPrefix("Regards/") && $0.path != Self.adapterPath }
            .filter { $0.text.range(of: Self.centerPattern, options: .regularExpression) != nil }
            .map(\.path)

        #expect(centerNamers.isEmpty, "R57 gate G1: only \(Self.adapterPath) may name the center: \(centerNamers)")
    }

    // MARK: - G4: request building

    /// Files in `ios/Regards` outside the adapter folder that name a request or trigger type.
    private static func requestBuilders(in files: [(path: String, text: String)]) -> [String] {
        files
            .filter { $0.path.hasPrefix("Regards/") && !$0.path.hasPrefix(adapterFolder) }
            .filter { $0.text.range(of: requestBuildingPattern, options: .regularExpression) != nil }
            .map(\.path)
    }

    @Test("G4: only the adapter folder names a notification request or trigger type")
    func requestBuildingStaysInsideTheAdapterFolder() throws {
        let files = try Self.sources()
        // Fail closed, as above.
        #expect(files.count > 50, "scanned only \(files.count) files under \(Self.iosRoot.path)")
        #expect(files.contains { $0.path == Self.adapterPath }, "no file at \(Self.adapterPath)")

        let offenders = Self.requestBuilders(in: files)

        #expect(offenders.isEmpty, "R57 gate G4: only the adapter folder may name these types: \(offenders)")
    }

    // MARK: - Pattern controls

    /// Positive control: a pattern that matches nothing would pass the tests
    /// above for every file. Negative control: the call pattern skips
    /// `Task.cancel()` on purpose, and the 2 call shapes in the type's doc
    /// comment (an implicit-self call and a method reference) stay unmatched,
    /// so a pattern change that starts matching either one fails here and not
    /// in an unrelated file. The third shape listed there, request building
    /// through `makeRequest`, has no probe here.
    @Test("The patterns match real calls, the center and request types, and skip Task.cancel() and the blind spots")
    func patternsMatchRealAndMultiLineCalls() throws {
        let parity = try #require(
            Self.sources().first { $0.path == "RegardsTests/Platform/NotificationFakeParityTests.swift" }
        )
        #expect(Self.makesACall(parity.text))
        #expect(Self.makesACall("await notifications.cancel(\n    identifiers: ids)"))
        #expect(!Self.makesACall("task.cancel()"))
        #expect(!Self.makesACall("let add = notifications.schedule"))
        #expect(!Self.makesACall("try await schedule(request)"))
        let center = "let c = UNUserNotificationCenter.current()"
        #expect(center.range(of: Self.centerPattern, options: .regularExpression) != nil)

        let builders = [
            "UNCalendarNotificationTrigger(",
            "UNNotificationRequest(",
            "UNTimeIntervalNotificationTrigger(",
        ]
        for builder in builders {
            #expect(
                builder.range(of: Self.requestBuildingPattern, options: .regularExpression) != nil,
                "G4 pattern misses \(builder)"
            )
        }
        // The scan reports a file outside the adapter folder, and spares one inside it.
        let probe = "let r = UNNotificationRequest(identifier: id, content: c, trigger: t)"
        let found = Self.requestBuilders(in: [
            (path: "Regards/App/Probe.swift", text: probe),
            (path: Self.adapterFolder + "Probe.swift", text: probe),
        ])
        #expect(found == ["Regards/App/Probe.swift"])
    }
}
