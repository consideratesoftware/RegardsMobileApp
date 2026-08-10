import Foundation
import Testing
@testable import Regards

/// R25 — `CNContactsSource.fetchAllContacts` used to run `enumerateContacts`
/// synchronously on whatever cooperative-pool thread the runtime handed the
/// calling `async` function, which stalled that worker for as long as a
/// large address book took to enumerate (measured at ~5k contacts). The fix
/// is the shared `runOffCooperativePool` helper; `CNContactStore` itself
/// can't be faked (Apple seals it), so this test exercises the helper
/// directly with a synthetic workload sized to the same order of magnitude.
///
/// This deliberately doesn't assert on `Thread.current` identity: on Apple
/// platforms the default Swift concurrency executor and `DispatchQueue
/// .global` both draw worker threads from the same underlying pool, so
/// landing on the same OS thread by chance proves nothing either way. What
/// actually matters — and what R25 was about — is whether *other* async work
/// sharing the pool keeps making progress while the enumeration blocks,
/// which is what the ticker below measures.
struct ContactsSourceTests {

    @Test("A synthetic 5k-contact enumeration keeps the cooperative pool responsive")
    func fiveThousandSyntheticContactsDoNotStarveTheCooperativePool() async throws {
        let ticker = CooperativePoolTicker()
        let tickerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
                await ticker.tick()
            }
        }

        let contacts = try await runOffCooperativePool { () -> [SystemContact] in
            var results: [SystemContact] = []
            results.reserveCapacity(5_000)
            // Mirrors CNContactStore's real shape: a single blocking call
            // that streams results in a synchronous loop. Chunking in a
            // sleep every 500 contacts reproduces a stall long enough to
            // prove pool responsiveness deterministically, independent of
            // the host machine's CPU speed.
            for chunkStart in stride(from: 0, to: 5_000, by: 500) {
                for index in chunkStart..<(chunkStart + 500) {
                    results.append(SystemContact(
                        identifier: "synthetic-\(index)",
                        givenName: "Synthetic",
                        familyName: "Contact \(index)",
                        phoneNumbers: [],
                        emailAddresses: []
                    ))
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return results
        }

        tickerTask.cancel()
        let ticks = await ticker.count

        #expect(contacts.count == 5_000)
        #expect(Set(contacts.map(\.identifier)).count == 5_000)
        // ~100ms of blocking work at a 5ms tick interval implies ~20 ticks
        // if the pool stayed free the whole time; require a fraction of that
        // as a generous, CI-noise-tolerant lower bound.
        #expect(ticks >= 5)
    }
}

private actor CooperativePoolTicker {
    private(set) var count = 0
    func tick() { count += 1 }
}
