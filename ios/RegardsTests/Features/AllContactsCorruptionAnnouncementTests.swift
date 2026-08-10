import Foundation
import SwiftUI
import Testing
@testable import Regards

/// Should-fix 9: when `corruptionMessage` newly becomes non-nil — whether on
/// first load or a later `reconciliationGeneration`-driven reload — the
/// screen must post a VoiceOver announcement, the same repo pattern
/// `RegardsApp`/`OnboardingScreen` already use for their own recoverable
/// states. This hosts the real screen (SwiftUI `.task`/`.onChange`
/// lifecycle, no UIKit accessibility-tree walking — that path is
/// CI-fragile, see the deleted `AllContactsCorruptionAccessibilityTests`)
/// and asserts through an injected effects closure instead.
@MainActor
struct AllContactsCorruptionAnnouncementTests {
    @Test("The corruption banner announces once when it newly appears, and doesn't re-announce while it stays non-nil")
    func announcesOnlyOnNilToNonNilTransition() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let healthy = Contact(systemContactRef: "healthy-1", displayName: "Healthy", tracked: false)
        let repository = MutableDiagnosticsRepository(
            report: ContactFetchReport(contacts: [healthy], corrupted: [])
        )
        let viewModel = AllContactsViewModel(contacts: repository, clock: { now })
        let model = ReconciliationGenerationModel()
        let recorder = AnnouncementRecorder()
        let host = UIHostingController(
            rootView: AnnouncementHarness(viewModel: viewModel, model: model, recorder: recorder)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // Initial load has no corruption — no announcement.
        #expect(await eventually { viewModel.loadState == .loaded })
        #expect(recorder.announcements.isEmpty)

        // Reconciliation discovers a corrupt row: nil → "1 contact...".
        await repository.setReport(Self.report(healthy: healthy, corruptedCount: 1))
        model.reconciliationGeneration += 1

        #expect(await eventually { recorder.announcements.count == 1 })
        #expect(recorder.announcements == ["1 contact couldn't be read and needs attention."])

        // A further reload finds a *second* corrupt row: "1 contact..." →
        // "2 contacts..." is a genuine value change (SwiftUI's `.onChange`
        // does fire), but the message was already non-nil, so the
        // nil-to-non-nil guard must still suppress a second announcement.
        await repository.setReport(Self.report(healthy: healthy, corruptedCount: 2))
        model.reconciliationGeneration += 1

        #expect(await eventually { viewModel.corruptedContactCount == 2 })
        #expect(recorder.announcements.count == 1)

        window.isHidden = true
    }

    private static func report(healthy: Contact, corruptedCount: Int) -> ContactFetchReport {
        ContactFetchReport(
            contacts: [healthy],
            corrupted: (0..<corruptedCount).map { index in
                ContactCorruptionDiagnostic(
                    rawId: "bad-\(index)", systemContactRef: "bad-\(index)", reason: "decode failed"
                )
            }
        )
    }
}

@MainActor
private final class ReconciliationGenerationModel: ObservableObject {
    @Published var reconciliationGeneration = 0
}

@MainActor
private final class AnnouncementRecorder {
    private(set) var announcements: [String] = []
    func record(_ message: String) {
        announcements.append(message)
    }
}

private struct AnnouncementHarness: View {
    let viewModel: AllContactsViewModel
    @ObservedObject var model: ReconciliationGenerationModel
    let recorder: AnnouncementRecorder

    var body: some View {
        var screen = AllContactsScreen(
            viewModel: viewModel,
            searchText: .constant(""),
            reconciliationGeneration: model.reconciliationGeneration
        )
        screen.corruptionAnnouncementEffects = AllContactsCorruptionAnnouncementEffects(
            announce: { message in recorder.record(message) }
        )
        return screen
    }
}

private actor MutableDiagnosticsRepository: ContactRepository {
    private var report: ContactFetchReport

    init(report: ContactFetchReport) {
        self.report = report
    }

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

    func setReport(_ newReport: ContactFetchReport) {
        report = newReport
    }
}
