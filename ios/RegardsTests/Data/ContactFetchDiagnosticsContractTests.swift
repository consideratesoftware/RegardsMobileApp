import Foundation
import Testing
@testable import Regards

/// R50 shared contract: `fetchAllWithDiagnostics()` must agree with
/// `fetchAll()` on both backends when nothing is corrupt. Split out of
/// `RepositoriesTests.swift` to keep that file under the lint length limit;
/// GRDB's actual per-row corruption behavior is covered directly by
/// `AllContactsViewModelTests` and `ContactsReconcilerTests`, which inject a
/// corrupt row GRDB-side (a mock store can never produce one — every write
/// round-trips through `ContactRecord` first).
struct ContactFetchDiagnosticsContractTests {
    @Test(
        "fetchAllWithDiagnostics matches fetchAll with no diagnostics when nothing is corrupt",
        arguments: RepositoryContractBackend.allCases
    )
    func fetchAllWithDiagnosticsMatchesFetchAllWhenHealthy(backend: RepositoryContractBackend) async throws {
        let repositories = try backend.makeRepositories()
        let contact = contractContact(id: try contractUUID(131), suffix: "diagnostics")
        try await repositories.contacts.upsert(contact)

        let report = try await repositories.contacts.fetchAllWithDiagnostics()
        let plain = try await repositories.contacts.fetchAll()

        #expect(Set(report.contacts.map(\.id)) == Set(plain.map(\.id)))
        #expect(report.corrupted.isEmpty)
    }
}
