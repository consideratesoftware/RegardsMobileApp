import Foundation
import Testing

/// R57 gate (ARCHITECTURE.md §19). `SchedulingPass.snooze` now resolves through the contact's effective window, with
/// a floor of the tap time plus 7 calendar days, so a snoozed row is already in-window. The OS request arrives in
/// TF-07e. Until then, this test keeps the notification center inside
/// `Platform/Notifications/NotificationScheduling.swift`, keeps `add` out of that file, and pins how many times that
/// file names the center, so any new route to it fails here.
///
/// This test scans raw source text, comments included. It catches accidental wiring. It can't prove that arbitrary
/// source changes are safe: a selector string, reflection, or a deliberate rewrite of one of the 3 pinned call sites
/// can get past it. Deliberate evasion is for code review to catch, and a reviewer should treat any edit to this
/// file's patterns or counts as wiring notification scheduling. TF-07e deletes this file in the PR that resolves R57,
/// and removes the request-building rule (G4) along with the rest of it.
struct NotificationSchedulingGateTests {
    private static let adapterRelativePath = "Platform/Notifications/NotificationScheduling.swift"

    private static let centerPattern = #"\bUNUserNotificationCenter\b"#
    private static let currentCenterPattern = #"\bUNUserNotificationCenter\.current\(\)"#
    private static let addPattern = #"\badd\b"#
    private static let requestBuildingPattern = #"\bUNNotificationRequest\b|\bUN\w*NotificationTrigger\b"#

    /// The adapter names the center 4 times: `.current()` in `install`,
    /// `requestAuthorization` and `authorizationStatus`, plus the delegate
    /// method's required `_ center: UNUserNotificationCenter` parameter.
    private static let pinnedCenterReferences = 4
    private static let pinnedCurrentCalls = 3

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

    /// Scans the tree, failing closed if it looks wrong, and returns the
    /// adapter's text and every other file.
    private static func scan() throws -> (adapter: String, others: [(path: String, text: String)]) {
        let files = try sources()
        #expect(files.count > 50, "scanned only \(files.count) files under \(sourceRoot.path)")
        let adapter = try #require(
            files.first { $0.path == adapterRelativePath }, "no file at \(adapterRelativePath)"
        )
        return (adapter.text, files.filter { $0.path != adapterRelativePath })
    }

    private static func matchCount(_ pattern: String, in text: String) throws -> Int {
        try NSRegularExpression(pattern: pattern).numberOfMatches(
            in: text, range: NSRange(text.startIndex..., in: text)
        )
    }

    @Test("G1: no file except the adapter names the notification center")
    func onlyTheAdapterNamesTheNotificationCenter() throws {
        let offenders = try Self.scan().others
            .filter { try Self.matchCount(Self.centerPattern, in: $0.text) > 0 }
            .map(\.path)

        #expect(offenders.isEmpty, "R57 gate G1: only the adapter may name the notification center. \(offenders)")
    }

    @Test("G2: the adapter never calls add")
    func theAdapterNeverCallsAdd() throws {
        let adds = try Self.matchCount(Self.addPattern, in: Self.scan().adapter)

        #expect(adds == 0, "R57 gate G2: the adapter contains the word add \(adds) time(s)")
    }

    @Test("G3: the adapter names the center exactly 4 times, 3 of them as .current()")
    func theAdapterCenterReferencesArePinned() throws {
        let adapter = try Self.scan().adapter

        #expect(try Self.matchCount(Self.centerPattern, in: adapter) == Self.pinnedCenterReferences)
        #expect(try Self.matchCount(Self.currentCenterPattern, in: adapter) == Self.pinnedCurrentCalls)
    }

    @Test("G4: no file, adapter included, names UNNotificationRequest or a notification trigger")
    func noFileBuildsNotificationRequests() throws {
        let scanned = try Self.scan()
        let files = scanned.others + [(path: Self.adapterRelativePath, text: scanned.adapter)]
        let offenders = try files
            .filter { try Self.matchCount(Self.requestBuildingPattern, in: $0.text) > 0 }
            .map(\.path)

        #expect(offenders.isEmpty, "R57 gate G4: nothing may build notification requests until TF-07. \(offenders)")
    }

    @Test("The gate patterns match on raw text, odd spacing and backticks included")
    func gatePatternsMatchOnRawText() throws {
        let imageFixture = "let t = \"image/*\"\n_ = UNUserNotificationCenter.current()"
        let g1Matches = ["`UNUserNotificationCenter`", imageFixture]
        let g2Matches = ["center.add (r)", "center.`add`(r)", "let f = center.add", "// add"]
        let g4Matches = ["UNNotificationRequest(", "UNCalendarNotificationTrigger("]
        let neverMatches = [
            "address", "addingTimeInterval", "UNUserNotificationCenterDelegate",
            "UNNotificationResponse", "UNNotificationCategory",
        ]

        for text in g1Matches {
            #expect(try Self.matchCount(Self.centerPattern, in: text) > 0, "G1 should match: \(text)")
        }
        for text in g2Matches {
            #expect(try Self.matchCount(Self.addPattern, in: text) > 0, "G2 should match: \(text)")
        }
        for text in g4Matches {
            #expect(try Self.matchCount(Self.requestBuildingPattern, in: text) > 0, "G4 should match: \(text)")
        }
        for text in neverMatches {
            #expect(try Self.matchCount(Self.requestBuildingPattern, in: text) == 0, "G4 should not match: \(text)")
            #expect(try Self.matchCount(Self.centerPattern, in: text) == 0, "G1 should not match: \(text)")
            #expect(try Self.matchCount(Self.addPattern, in: text) == 0, "G2 should not match: \(text)")
        }
    }
}
