import Foundation

/// The DEBUG-only launch-argument factory (`--regards-mock-runtime` and the
/// UI-test-only launch scenarios) plus its fixture types, which are private
/// except `DebugNotificationScheduling`, because unit tests use it too. Split
/// from `AppLaunchCoordinator.swift` to keep that file's primary type body
/// under the lint length limit — this factory only calls
/// `AppLaunchCoordinator`'s initializers, so nothing else here needed to
/// become less private except `init(mockRuntime:)` itself, which the
/// file-split forced from `private` to plain `internal`.
extension AppLaunchCoordinator {
    // MARK: - Launch factory

#if DEBUG
    static func configuredForCurrentProcess() -> AppLaunchCoordinator {
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--regards-mock-runtime") {
            // `unavailable` passes no notification seam at all, so a UI test
            // can check that Settings shows no Notifications section.
            let notificationStatus = environment["REGARDS_UI_TEST_NOTIFICATION_STATUS"] ?? ""
            return AppLaunchCoordinator(
                mockRuntime: .makeMock(
                    includeDuplicateFixture:
                        environment["REGARDS_UI_TEST_DUPLICATE_FIXTURE"] == "1",
                    seedCorruptRow:
                        environment["REGARDS_UI_TEST_SEED_CORRUPT_ROW"] == "1"
                ),
                // Never the real adapter here: a system permission alert
                // would cover the accessibility audits this launch serves.
                notifications: notificationStatus == "unavailable"
                    ? nil
                    : DebugNotificationScheduling(
                        status: NotificationAuthorizationStatus(rawValue: notificationStatus) ?? .notDetermined,
                        // `fail` makes the system request throw, so a UI test
                        // can reach the Settings request-error line.
                        requestOutcome: environment["REGARDS_UI_TEST_NOTIFICATION_REQUEST_OUTCOME"] == "fail"
                            ? .fail
                            : .grant
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

// MARK: - DEBUG fixtures

#if DEBUG
/// Fake `NotificationScheduling` for the `--regards-mock-runtime` launch and
/// unit tests. It never touches the system notification
/// center, so it never raises the permission alert. The status is whatever
/// the caller passes (the mock launch reads `REGARDS_UI_TEST_NOTIFICATION_STATUS`),
/// a request from `.notDetermined` resolves to the scripted `requestOutcome`,
/// and `send(_:)` delivers an action as if the user tapped it.
///
/// An actor because the status changes after a request and tests read
/// `requestCount` across tasks. `actions` and `send(_:)` are `nonisolated`:
/// `AsyncStream` and its `Continuation` are `Sendable` and thread-safe.
actor DebugNotificationScheduling: NotificationScheduling {
    enum RequestOutcome: Sendable {
        case grant
        case deny
        case fail
    }

    struct RequestFailed: Error {}

    nonisolated let actions: AsyncStream<NotificationAction>
    private nonisolated let continuation: AsyncStream<NotificationAction>.Continuation
    private var status: NotificationAuthorizationStatus
    private let requestOutcome: RequestOutcome
    /// How many times `requestAuthorization()` ran, prompt or not.
    private(set) var requestCount = 0

    init(status: NotificationAuthorizationStatus = .notDetermined, requestOutcome: RequestOutcome = .grant) {
        (actions, continuation) = AsyncStream.makeStream(of: NotificationAction.self, bufferingPolicy: .unbounded)
        self.status = status
        self.requestOutcome = requestOutcome
    }

    /// Mirrors iOS: only `.notDetermined` prompts. Once decided, a request
    /// returns the existing decision without changing it.
    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        guard status == .notDetermined else { return status == .authorized }
        switch requestOutcome {
        case .grant:
            status = .authorized
            return true
        case .deny:
            status = .denied
            return false
        case .fail:
            throw RequestFailed()
        }
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus { status }

    /// Simulates the user changing the permission in iOS Settings.
    func setStatus(_ newStatus: NotificationAuthorizationStatus) {
        status = newStatus
    }

    nonisolated func send(_ action: NotificationAction) {
        continuation.yield(action)
    }
}

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
