import Testing
@testable import Regards

extension AppLaunchCoordinatorTests {
    @Test("Limited authorization resumes import like full authorization")
    func limitedAuthorizationImportsLikeAuthorized() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(
            status: .limited,
            contacts: [Self.systemContact]
        )
        let launch = coordinator(environment: environment, source: source)

        await launch.start()

        #expect(launch.phase == .ready)
        let runtime = try #require(launch.runtime)
        #expect(try await runtime.environment.contacts.fetchAll().count == 1)
        #expect(try await runtime.environment.profile.fetch().onboardingCompletedAt == now)
        #expect(await source.counts() == .init(current: 2, requests: 0, fetches: 1))
    }

    @Test("Restricted authorization offers the same browse-only recovery as denial")
    func restrictedAuthorizationOffersBrowseOnly() async throws {
        let environment = try ProductionRepositoryFactory.makeInMemoryEnvironment()
        let source = ScriptedLaunchContactsSource(status: .restricted)
        let launch = coordinator(environment: environment, source: source)

        await launch.start()

        #expect(launch.phase == .onboarding)
        #expect(launch.canContinueWithoutContacts)
        #expect(launch.statusMessage != nil)
        #expect(await source.counts() == .init(current: 1, requests: 0, fetches: 0))

        await launch.continueWithoutContacts()
        #expect(launch.phase == .ready)
        let runtime = try #require(launch.runtime)
        #expect(try await runtime.environment.profile.fetch().onboardingCompletedAt == now)
    }
}
