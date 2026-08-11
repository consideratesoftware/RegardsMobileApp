import Foundation
import SwiftUI
import Testing
@testable import Regards

/// Blocker: `AllContactsScreen` must reload when `reconciliationGeneration`
/// changes, not on raw `scenePhase` (which races `AppLaunchCoordinator`'s
/// own reconciliation pass and can show pre-reconciliation data — see
/// `AllContactsScreen.reconciliationGeneration`'s doc comment). This is the
/// hole that let that race ship: it hosts the real screen, mutates the
/// underlying store the way a completed reconciliation pass would, bumps
/// `reconciliationGeneration` through the screen's actual parameter (not a
/// direct `viewModel.load()` call), and proves the view model reflects the
/// new data through SwiftUI's own observation path.
@MainActor
struct AllContactsScreenReconciliationTests {
    @Test("The screen reloads via reconciliationGeneration observation, not a manual load() call")
    func reloadsWhenReconciliationGenerationChanges() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repository = SettableContactRepository(
            contacts: [Self.contact(name: "Before Reconcile")]
        )
        let viewModel = AllContactsViewModel(contacts: repository, clock: { now })
        let model = ReconciliationGenerationModel()
        let host = UIHostingController(
            rootView: ReconciliationGenerationHarness(viewModel: viewModel, model: model)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        // The screen's own `.task` load reflects the pre-reconciliation
        // state first.
        #expect(await eventually { viewModel.contacts.map(\.displayName) == ["Before Reconcile"] })

        // Mutate the store the way a completed `ContactsReconciler.reconcile()`
        // pass would, entirely independently of the screen — it never calls
        // `viewModel.load()` itself here, only `model.reconciliationGeneration`
        // changes, exactly like `AppLaunchCoordinator.reconciliationCount`
        // incrementing after a pass.
        await repository.replaceContacts([Self.contact(name: "After Reconcile")])
        model.reconciliationGeneration += 1

        #expect(await eventually { viewModel.contacts.map(\.displayName) == ["After Reconcile"] })

        window.isHidden = true
    }

    private static func contact(name: String) -> Contact {
        Contact(systemContactRef: "ref-\(name)", displayName: name, tracked: false)
    }
}

@MainActor
private final class ReconciliationGenerationModel: ObservableObject {
    @Published var reconciliationGeneration = 0
}

private struct ReconciliationGenerationHarness: View {
    let viewModel: AllContactsViewModel
    @ObservedObject var model: ReconciliationGenerationModel

    var body: some View {
        AllContactsScreen(
            viewModel: viewModel,
            searchText: .constant(""),
            reconciliationGeneration: model.reconciliationGeneration
        )
    }
}

// `SettableContactRepository` lives in RegardsTests/Support — shared across
// the AllContacts reconciliation/announcement suites.
