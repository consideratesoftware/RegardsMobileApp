import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Regards

/// R50's corruption banner never appears in the XCUITest audit fixtures (the
/// mock runtime never produces a corrupt row), so `performAccessibilityAudit
/// ()` never sees `contacts.corruption-banner`. This hosts the real screen
/// against an injected `ContactFetchReport` that carries one corrupt
/// diagnostic and inspects the resulting UIKit accessibility tree directly —
/// the same `accessibilityElements`/`accessibilityLabel` surface VoiceOver
/// and the audit both read — so the banner's accessibility contract is
/// still proven even though the XCUITest fixtures can't reach it yet.
///
/// Lookup is by accessibility **label**, not `accessibilityIdentifier`:
/// empirically (confirmed by dumping the live tree during development).
/// SwiftUI's internal `AccessibilityNode` exposes `accessibilityLabel` and
/// `isAccessibilityElement` directly (both are plain `NSObject` members via
/// UIKit's `UIAccessibility` category), but `accessibilityIdentifier` reads
/// back `nil` in-process — identifier lookups apparently only resolve
/// through the real out-of-process accessibility server, which an
/// `XCUIApplication` talks to but a hosted unit test doesn't. The visible
/// message text is unique enough in this fixture to identify the banner
/// unambiguously without it.
@MainActor
struct AllContactsCorruptionAccessibilityTests {
    @Test("The corruption banner's combined accessibility label equals its visible message")
    func corruptionBannerAccessibilityLabelMatchesVisibleMessage() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let healthy = Contact(systemContactRef: "healthy-1", displayName: "Healthy Contact", tracked: false)
        let repository = FixedDiagnosticsContactRepository(
            report: ContactFetchReport(
                contacts: [healthy],
                corrupted: [
                    ContactCorruptionDiagnostic(
                        rawId: "bad-id", systemContactRef: "corrupt-1", reason: "decode failed"
                    ),
                ]
            )
        )
        let viewModel = AllContactsViewModel(contacts: repository, clock: { now })
        await viewModel.load()
        #expect(viewModel.corruptedContactCount == 1)
        let expectedMessage = try #require(viewModel.corruptionMessage)
        let expectedSummary = viewModel.summary

        let screen = AllContactsScreen(viewModel: viewModel, searchText: .constant(""))
        let host = UIHostingController(rootView: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()

        // SwiftUI materializes its UIKit-facing accessibility tree during a
        // real run-loop pass tied to the CATransaction commit. `Task.yield()`
        // only reschedules *Swift concurrency* tasks — it never pumps the
        // actual `CFRunLoop`, so it can't force that commit on its own. A
        // single fixed warm-up spin before switching to yield-only polling
        // is fragile: on a slower/colder simulator (observed: a freshly
        // erased-and-booted one took over 15s for this exact tree to
        // materialize, vs. under a second on a warm one) the tree simply
        // isn't ready yet when the fixed window ends, and yield-only polling
        // after that never helps it along. So every iteration here pumps the
        // run loop itself and re-checks — bounded by iteration count, not by
        // a single elapsed-time budget, and it returns the instant the tree
        // appears rather than always paying the worst case.
        var matches: [NSObject] = []
        let found = pollUntilTrue {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            matches = findAccessibilityElements(withLabel: expectedMessage, in: window)
            return !matches.isEmpty
        }
        #expect(found)

        // Exactly one element carries the banner's combined label — proves
        // it renders once, not duplicated across the tree's two hosting
        // branches windows sometimes produce during layout settling.
        let banner = try #require(matches.first)
        #expect(matches.count == 1)
        #expect(banner.isAccessibilityElement == true)
        // `.accessibilityElement(children: .combine)` merges the banner's
        // text and icon into one element; the icon carries
        // `.accessibilityHidden(true)`. The label matched exactly (not
        // `.contains`) to get here, which already proves the icon
        // contributed nothing extra to the combined label — and the
        // "N contact(s)" summary line renders as its own separate element
        // alongside it, not merged into the banner.
        let summaryMatches = findAccessibilityElements(withLabel: expectedSummary, in: window)
        #expect(!summaryMatches.isEmpty)
        #expect(summaryMatches.allSatisfy { $0 !== banner })

        window.isHidden = true
    }
}

/// A `ContactRepository` whose `fetchAllWithDiagnostics()` always returns a
/// fixed report, so tests can render the corruption banner without needing a
/// real corrupt GRDB row.
private struct FixedDiagnosticsContactRepository: ContactRepository {
    let report: ContactFetchReport

    func fetchAll() async throws -> [Contact] { report.contacts }
    func fetchTracked() async throws -> [Contact] {
        report.contacts.filter { $0.tracked && $0.isActive }
    }
    func fetch(id: UUID) async throws -> Contact? { report.contacts.first { $0.id == id } }
    func fetchMembers(ofGroup groupId: UUID) async throws -> [Contact] {
        report.contacts.filter { $0.contactGroupId == groupId }
    }
    func upsert(_ contact: Contact) async throws {}
    func archive(id: UUID, at: Date) async throws {}
    func fetchAllWithDiagnostics() async throws -> ContactFetchReport { report }
}

/// Recursively walks a hosted view's UIKit-exposed accessibility tree,
/// collecting every accessible element (`isAccessibilityElement == true`)
/// whose label matches exactly. SwiftUI content exposes itself to UIKit
/// (and therefore to VoiceOver and `performAccessibilityAudit()`) through
/// the same `accessibilityElements` mechanism a hand-written
/// `UIAccessibilityContainer` would use, so this walks the identical path —
/// just from a unit test instead of an XCUITest host app. Walking twice
/// (once per hosting branch a settling window can momentarily produce) can
/// find the same logical element more than once by identity in edge cases;
/// callers that care about "exactly one" should still sanity-check the
/// result, which the test above does.
@MainActor
func findAccessibilityElements(withLabel label: String, in root: NSObject) -> [NSObject] {
    var results: [NSObject] = []
    if root.isAccessibilityElement, root.accessibilityLabel == label {
        results.append(root)
    }
    // A container that declares an explicit `accessibilityElements` list
    // uses *that* as its accessible children instead of its normal
    // subviews — same rule UIKit itself applies. Walking both would visit
    // the same logical child twice through two different paths.
    if let children = root.accessibilityElements {
        for case let child as NSObject in children {
            results.append(contentsOf: findAccessibilityElements(withLabel: label, in: child))
        }
    } else if let view = root as? UIView {
        for subview in view.subviews {
            results.append(contentsOf: findAccessibilityElements(withLabel: label, in: subview))
        }
    }
    return results
}

/// Polls `condition`, pumping the real run loop for `iterationInterval`
/// between checks — unlike `Task.yield()` (Swift-concurrency-only
/// rescheduling), this actually lets a pending `CATransaction` commit, which
/// is what makes SwiftUI materialize its UIKit-facing accessibility tree in
/// the first place. Bounded by `maxIterations`, not by a single elapsed-time
/// budget: it returns `true` the instant `condition()` succeeds, so a fast
/// environment pays only what it needs, and a slow one gets up to
/// `maxIterations * iterationInterval` (300 * 0.05s = 15s) before giving up
/// — calibrated against a freshly erased-and-booted simulator, where this
/// exact tree was observed taking a bit over that on a cold first render.
/// `RunLoop.current` is `noasync`, so this whole helper stays a plain
/// synchronous function the (async) test calls without `await`.
private func pollUntilTrue(
    maxIterations: Int = 300,
    iterationInterval: TimeInterval = 0.05,
    _ condition: () -> Bool
) -> Bool {
    for _ in 0..<maxIterations {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(iterationInterval))
    }
    return condition()
}
