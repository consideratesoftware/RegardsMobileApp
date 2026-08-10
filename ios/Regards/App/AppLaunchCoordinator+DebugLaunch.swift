import Foundation

/// The DEBUG-only launch-argument factory (`--regards-mock-runtime` and the
/// UI-test-only launch scenarios) plus its private fixture types. Split from
/// `AppLaunchCoordinator.swift` to keep that file's primary type body under
/// the lint length limit — this factory only calls `AppLaunchCoordinator`'s
/// initializers, so nothing here needed to become less private except
/// `init(mockRuntime:)` itself, which the file-split forced from `private`
/// to plain `internal`.
extension AppLaunchCoordinator {
#if DEBUG
    static func configuredForCurrentProcess() -> AppLaunchCoordinator {
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--regards-mock-runtime") {
            return AppLaunchCoordinator(
                mockRuntime: .makeMock(
                    includeDuplicateFixture:
                        environment["REGARDS_UI_TEST_DUPLICATE_FIXTURE"] == "1",
                    seedCorruptRow:
                        environment["REGARDS_UI_TEST_SEED_CORRUPT_ROW"] == "1"
                )
            )
        }
        if arguments.contains("--regards-launch-fails-once") {
            let runtimeFactory = FirstLaunchUITestRuntimeFactory()
            return AppLaunchCoordinator(
                dependencies: Dependencies(
                    makeRuntime: { try await runtimeFactory.makeRuntime() },
                    contactsSource: FirstLaunchUITestContactsSource(outcome: .authorized),
                    clock: { Date(timeIntervalSince1970: 1_785_600_000) }
                )
            )
        }
        if arguments.contains("--regards-first-launch-runtime") {
            let contactsOutcome = FirstLaunchUITestContactsOutcome(
                rawValue: environment["REGARDS_UI_TEST_CONTACTS_OUTCOME"] ?? "authorized"
            ) ?? .authorized
            return AppLaunchCoordinator(
                dependencies: Dependencies(
                    makeRuntime: {
                        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
                        return try await AppRuntime.makeProduction(environment: environment)
                    },
                    contactsSource: FirstLaunchUITestContactsSource(outcome: contactsOutcome),
                    clock: { Date(timeIntervalSince1970: 1_785_600_000) }
                )
            )
        }
        if arguments.contains("--regards-ready-without-runtime") {
            return AppLaunchCoordinator(
                dependencies: Dependencies(
                    makeRuntime: {
                        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
                        return try await AppRuntime.makeProduction(environment: environment)
                    },
                    contactsSource: FirstLaunchUITestContactsSource(outcome: .authorized),
                    clock: { Date(timeIntervalSince1970: 1_785_600_000) }
                ),
                testingPhase: .ready
            )
        }
        return production()
    }
#else
    static func configuredForCurrentProcess() -> AppLaunchCoordinator {
        production()
    }
#endif
}

#if DEBUG
private enum FirstLaunchUITestContactsOutcome: String {
    case authorized
    case denied
    case deniedAtLaunch = "denied-at-launch"
    case importFailsOnce = "import-fails-once"
}

private enum FirstLaunchUITestContactsError: Error {
    case fetchFailed
}

private enum FirstLaunchUITestRuntimeError: Error {
    case openFailed
}

private actor FirstLaunchUITestRuntimeFactory {
    private var shouldFail = true

    func makeRuntime() async throws -> AppRuntime {
        if shouldFail {
            shouldFail = false
            throw FirstLaunchUITestRuntimeError.openFailed
        }
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        return try await AppRuntime.makeProduction(environment: environment)
    }
}

private actor FirstLaunchUITestContactsSource: ContactsSource {
    private let outcome: FirstLaunchUITestContactsOutcome
    private var status: ContactsAuthorizationStatus = .notDetermined
    private var remainingFetchFailures: Int

    init(outcome: FirstLaunchUITestContactsOutcome) {
        self.outcome = outcome
        if outcome == .deniedAtLaunch {
            self.status = .denied
        }
        self.remainingFetchFailures = outcome == .importFailsOnce ? 1 : 0
    }

    func currentAuthorization() async -> ContactsAuthorizationStatus { status }

    func requestAccess() async throws -> ContactsAuthorizationStatus {
        status = outcome == .denied || outcome == .deniedAtLaunch ? .denied : .authorized
        return status
    }

    func fetchAllContacts() async throws -> [SystemContact] {
        if remainingFetchFailures > 0 {
            remainingFetchFailures -= 1
            throw FirstLaunchUITestContactsError.fetchFailed
        }
        return [
            SystemContact(
                identifier: "ui-test-contact",
                givenName: "Leia",
                familyName: "Organa",
                phoneNumbers: ["+1 555 010 2000"],
                emailAddresses: ["leia@example.com"]
            ),
        ]
    }
}
#endif
