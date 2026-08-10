import Foundation
import Testing
@testable import Regards

/// Round 11: `AppLaunchCoordinator.previouslyMissingContactRefs` (rounds
/// 9–10) was `@ObservationIgnored`, in-memory only, and reset to empty on
/// every process launch. A hosted reviewer caught the real production bug
/// that produces: the archive-debounce rule needs two consecutive
/// `.authorized` passes at least `ContactsReconciler.archiveDebounceFloor`
/// (5 minutes) apart, but the app is rarely kept foregrounded continuously
/// for 5+ minutes on iOS, and any relaunch in between reset the state — so
/// in practice, a genuine contact deletion almost never got both halves of
/// "two passes" inside one process lifetime and effectively never archived.
/// `MissingContactRefStore` persists that state (Application Support,
/// `NSFileProtectionComplete`, `ContactRefHasher`-hashed keys) across
/// launches to close that gap. These tests exercise the coordinator-level
/// integration; `ContactsReconcilerAuthorizationTests` covers the
/// underlying two-pass, time-floored rule itself.
@MainActor
struct AppLaunchArchivePersistenceTests {
    let now = Date(timeIntervalSince1970: 1_785_600_000)

    @Test("""
    Archive-debounce state survives a relaunch: a new coordinator over the \
    same store archives what the previous one only recorded as missing
    """)
    func archiveDebounceStateSurvivesRelaunch() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let contact = Contact(systemContactRef: "cross-launch-deleted", displayName: "Gone", tracked: true)
        try await environment.contacts.upsert(contact)
        let sharedStore = try MissingContactRefStore(directory: Self.freshTempDirectory())
        let clock = MutableClock(now)

        // "Coordinator A" — one process launch. The contact is already
        // missing from its very first (and, for this test, only) pass.
        let sourceA = MutableContactsSource(status: .authorized, contacts: [])
        let coordinatorA = Self.coordinator(
            environment: environment, source: sourceA, clock: clock.now, missingContactRefStore: sharedStore
        )
        await coordinatorA.start()
        #expect(coordinatorA.reconciliationCount == 1)
        let stillActiveAfterProcessA = try await environment.contacts.fetch(id: contact.id)
        #expect(stillActiveAfterProcessA?.archivedAt == nil)

        // The app relaunches: a brand-new `AppLaunchCoordinator` — fresh
        // in-memory state, `previouslyMissingContactRefs` back to empty —
        // pointed at the *same* sidecar store. If that state weren't
        // persisted, this pass would look like a first-ever miss all over
        // again and never archive, no matter how much time passed.
        clock.advance(by: ContactsReconciler.archiveDebounceFloor)
        let sourceB = MutableContactsSource(status: .authorized, contacts: [])
        let coordinatorB = Self.coordinator(
            environment: environment, source: sourceB, clock: clock.now, missingContactRefStore: sharedStore
        )
        await coordinatorB.start()

        #expect(coordinatorB.reconciliationCount == 1)
        let archived = try await environment.contacts.fetch(id: contact.id)
        #expect(archived?.archivedAt == clock.now())
    }

    /// The persisted-store wiring must not change the restore-in-progress
    /// protection `ContactsReconcilerAuthorizationTests` already pins at
    /// the reconciler level: a contact that disappears and then reappears
    /// (Contacts still repopulating mid-restore) must never archive, no
    /// matter how much wall-clock time passes before it reappears — the
    /// reappearance itself is what clears the pending-miss tracking, not a
    /// timeout.
    @Test("""
    A transient disappearance that resolves before reconfirmation never \
    archives, even well past the debounce floor
    """)
    func transientDisappearanceResolvesWithoutArchiving() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let contact = Contact(systemContactRef: "resync-1", displayName: "Resync Target", tracked: true)
        try await environment.contacts.upsert(contact)
        let source = MutableContactsSource(status: .authorized, contacts: [
            SystemContact(identifier: "resync-1", givenName: "Resync", familyName: "Target",
                          phoneNumbers: [], emailAddresses: []),
        ])
        let clock = MutableClock(now)
        let launch = Self.coordinator(environment: environment, source: source, clock: clock.now)

        await launch.start()
        #expect(launch.reconciliationCount == 1)

        // Contacts briefly reports nothing visible at all — the shape a
        // mid-restore resync produces.
        source.setContacts([])
        await launch.handleSceneActivation()
        #expect(launch.reconciliationCount == 2)
        let stillActiveAfterFirstMiss = try await environment.contacts.fetch(id: contact.id)
        #expect(stillActiveAfterFirstMiss?.archivedAt == nil)

        // The resync finishes and the contact reappears — well past the
        // debounce floor, to prove elapsed time alone never archives a ref
        // that's back in view by the time it's checked again.
        clock.advance(by: ContactsReconciler.archiveDebounceFloor * 2)
        source.setContacts([
            SystemContact(identifier: "resync-1", givenName: "Resync", familyName: "Target",
                          phoneNumbers: [], emailAddresses: []),
        ])
        await launch.handleSceneActivation()

        #expect(launch.reconciliationCount == 3)
        let stillActive = try await environment.contacts.fetch(id: contact.id)
        #expect(stillActive?.archivedAt == nil)
    }

    @Test("The persisted archive-debounce sidecar never contains a raw systemContactRef")
    func persistedStoreContainsNoRawRefs() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        try await environment.profile.save(UserProfile(
            onboardingCompletedAt: now,
            entitlementTier: .trial,
            entitlementRefreshedAt: now,
            trialStartedAt: now
        ))
        let rawRef = "super-secret-raw-contact-identifier-should-never-appear-on-disk"
        let contact = Contact(systemContactRef: rawRef, displayName: "Sensitive", tracked: true)
        try await environment.contacts.upsert(contact)
        let directory = Self.freshTempDirectory()
        let store = try MissingContactRefStore(directory: directory)
        let source = MutableContactsSource(status: .authorized, contacts: [])
        let launch = Self.coordinator(environment: environment, source: source, missingContactRefStore: store)

        await launch.start()
        #expect(launch.reconciliationCount == 1)

        // White-box: `MissingContactRefStore`'s file name is an
        // implementation detail this test deliberately reaches past, the
        // same way other suites in this repo read raw SQL/JSON to prove a
        // persistence-layer guarantee directly against what's actually on
        // disk rather than through the type's own (trusted) accessors.
        let fileURL = directory.appendingPathComponent("contacts-archive-debounce.json")
        let fileContents = try #require(try? String(contentsOf: fileURL, encoding: .utf8))
        #expect(!fileContents.isEmpty)
        #expect(!fileContents.contains(rawRef), "the sidecar must never contain a raw systemContactRef")
        // Confirms the file genuinely recorded *something* — a SHA-256 hex
        // digest of the ref — rather than this test's first assertion
        // trivially passing because nothing was written at all.
        #expect(fileContents.contains(ContactRefHasher.hash(rawRef)))
    }

    private static func freshTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLaunchArchivePersistenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func coordinator(
        environment: AppEnvironment,
        source: any ContactsSource,
        clock: (@Sendable () -> Date)? = nil,
        missingContactRefStore: MissingContactRefStore = .ephemeral()
    ) -> AppLaunchCoordinator {
        let now = Date(timeIntervalSince1970: 1_785_600_000)
        return AppLaunchCoordinator(
            dependencies: .init(
                makeRuntime: {
                    try await AppRuntime.makeProduction(environment: environment)
                },
                contactsSource: source,
                clock: clock ?? { now },
                missingContactRefStore: missingContactRefStore
            )
        )
    }
}

// `MutableContactsSource`/`MutableClock` live in RegardsTests/Support —
// shared across the reconciliation suites.
