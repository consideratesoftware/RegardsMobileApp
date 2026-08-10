import Contacts
import Foundation
import Testing
@testable import Regards

/// R25 — `CNContactsSource.fetchAllContacts` used to run `enumerateContacts`
/// synchronously on whatever cooperative-pool thread the runtime handed the
/// calling `async` function, which stalled that worker for as long as a
/// large address book took to enumerate (measured at ~5k contacts). The fix
/// is the shared `runOffCooperativePool` helper; `CNContactStore` itself
/// can't be faked (Apple seals it), so these tests exercise the helper
/// directly or, for the production-tie regression below, through
/// `CNContactsSource`'s test-only enumeration override.
struct ContactsSourceTests {

    @Test("A synthetic 5k-contact enumeration returns every contact with a unique identifier")
    func fiveThousandSyntheticContactsAllReturn() async throws {
        let contacts = try await runOffCooperativePool { () -> [SystemContact] in
            (0..<5_000).map { index in
                SystemContact(
                    identifier: "synthetic-\(index)",
                    givenName: "Synthetic",
                    familyName: "Contact \(index)",
                    phoneNumbers: [],
                    emailAddresses: []
                )
            }
        }

        #expect(contacts.count == 5_000)
        #expect(Set(contacts.map(\.identifier)).count == 5_000)
    }

    /// Round 10: `ContactsSourceStressTests.offCooperativePoolSurvivesFullPoolSaturation`
    /// proves `runOffCooperativePool` itself works, but exercises it
    /// directly — deleting the call to it from `CNContactsSource
    /// .fetchAllContacts()` (the actual R25 call site) would leave that
    /// suite green, since it never calls `fetchAllContacts()` at all, so
    /// the acceptance criterion was unproven against the production code
    /// path. This test closes that gap: it drives the *real*
    /// `fetchAllContacts()` method — through `CNContactsSource`'s
    /// test-only `enumerateOverride` seam, since `CNContactStore` itself
    /// can't be faked with a populated address book — and proves a
    /// concurrent task still makes progress while `activeProcessorCount`
    /// concurrent calls to it are in flight. Same yield-counting,
    /// no-wall-clock shape as the stress suite, reusing its round 8
    /// mechanism verbatim (full saturation + a tight, not 5s-default,
    /// deadline on both the start signal and the ticks check — seconds
    /// 1-2 of that file's own doc comment cover exactly why a looser
    /// deadline doesn't discriminate).
    ///
    /// Confirmed by reverting `runOffCooperativePool` to run `work` inline
    /// at `fetchAllContacts()`'s call site and running this test 3
    /// consecutive times (see the round 10 report for the failure output);
    /// restored immediately after, verified clean.
    @Test("The real fetchAllContacts() call site keeps the cooperative pool responsive under saturation")
    func fetchAllContactsRealCallSiteSurvivesFullPoolSaturation() async throws {
        let concurrency = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let startedSemaphore = DispatchSemaphore(value: 0)
        let releaseSemaphore = DispatchSemaphore(value: 0)
        // Safety valve only, not the assertion — see
        // `ContactsSourceStressTests` for the full rationale this mirrors.
        let saturationSafetyValveSeconds = 5.0

        let source = CNContactsSource(store: CNContactStore()) {
            startedSemaphore.signal()
            _ = releaseSemaphore.wait(timeout: .now() + saturationSafetyValveSeconds)
            return (0..<5_000).map { index in
                SystemContact(
                    identifier: "synthetic-\(index)",
                    givenName: "Synthetic",
                    familyName: "Contact \(index)",
                    phoneNumbers: [],
                    emailAddresses: []
                )
            }
        }

        let fetchTasks = (0..<concurrency).map { _ in
            Task.detached { _ = try? await source.fetchAllContacts() }
        }

        // Tight, not the 5s safety valve above — see
        // `ContactsSourceStressTests`'s doc comment for why the 5s default
        // previously let a starved pool "just barely" pass this check.
        let startedDeadlineSeconds = 1.0
        var allStarted = true
        for _ in 0..<concurrency
        where waitWithBoundedTimeout(startedSemaphore, seconds: startedDeadlineSeconds) == .timedOut {
            allStarted = false
        }
        #expect(allStarted, """
            every saturating fetchAllContacts() call should report it started within \
            \(startedDeadlineSeconds)s — a saturated cooperative pool (the shape a \
            regression to running work inline at this call site produces) makes at \
            least one straggle well past this, all the way out to the \
            \(saturationSafetyValveSeconds)s safety valve above
            """)

        let iterations = concurrency * 4
        let ticksDeadlineSeconds = 1.0
        let ticksDeadlineSemaphore = DispatchSemaphore(value: 0)
        let ticksTask = Task.detached {
            for _ in 0..<iterations {
                await Task.yield()
            }
            ticksDeadlineSemaphore.signal()
        }
        let ticksOutcome = waitWithBoundedTimeout(ticksDeadlineSemaphore, seconds: ticksDeadlineSeconds)
        #expect(ticksOutcome == .success, """
            the cooperative pool was still unresponsive after \(ticksDeadlineSeconds)s while \
            \(concurrency) fetchAllContacts() calls were in flight — this is what a \
            regression to running work inline at that call site looks like
            """)

        for _ in 0..<concurrency { releaseSemaphore.signal() }
        for task in fetchTasks { _ = await task.value }
        // Only reachable promptly if `ticksOutcome` was `.success` — if it
        // timed out, the ticks task is still running (it isn't cancelled,
        // just no longer waited on with a deadline), so let it finish
        // rather than leaking it past this test's return.
        _ = await ticksTask.value
    }
}
