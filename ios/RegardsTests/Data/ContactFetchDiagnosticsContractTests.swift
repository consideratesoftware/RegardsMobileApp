import Foundation
import Testing
@testable import Regards

/// R50 shared contract: `fetchAllWithDiagnostics()` must agree with
/// `fetchAll()` on both backends when nothing is corrupt. Split out of
/// `RepositoriesTests.swift` to keep that file under the lint length limit;
/// the corruption-tolerant *diagnostics* read path is covered directly by
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

    /// Restores the fail-closed proof directly: `fetchAll()` itself is
    /// unchanged by R50 and must still throw on a corrupt row. Only
    /// `ContactsImporter`/`ContactsReconciler` moved off it (to
    /// `fetchAllWithDiagnostics()`) — every other caller, including
    /// duplicate detection, still needs the all-or-nothing guarantee.
    @Test("GRDB fetchAll() still throws on a corrupt row (R50 doesn't touch it)")
    func fetchAllStillThrowsOnCorruptRow() async throws {
        let database = try DatabaseFactory.makeInMemoryDatabase()
        let environment = ProductionRepositoryFactory.makeEnvironment(database: database)
        let corrupt = contractContact(id: try contractUUID(132), suffix: "still-throws")
        try await environment.contacts.upsert(corrupt)
        try await database.write { db in
            try db.execute(
                sql: "UPDATE Contact SET phonesJson = ? WHERE id = ?",
                arguments: ["null", corrupt.id.uuidString]
            )
        }

        await #expect(throws: (any Error).self) {
            _ = try await environment.contacts.fetchAll()
        }
    }
}
