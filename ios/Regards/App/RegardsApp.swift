import Foundation
import SwiftUI

@main @MainActor
struct RegardsApp: App {
    @State private var launch = AppLaunchCoordinator.configuredForCurrentProcess()

    var body: some Scene {
        WindowGroup {
            RootView(launch: launch)
                .modifier(UITestDynamicTypeOverride())
        }
    }
}

/// The first SwiftUI view the user sees. The splash remains visible until the
/// persisted runtime has loaded, then the profile decides whether onboarding
/// or the tab root is next.
struct RootView: View {
    @State var launch: AppLaunchCoordinator
    @State private var showsTransparency = false
    @State private var launchFailureEffectGeneration = 0
    /// Latch for the scenePhase gate below. Foregrounding always routes
    /// `.background → .inactive → .active`, so `oldPhase` at `.active` is
    /// always `.inactive`, never `.background` — this remembers "passed
    /// through `.background`" across that hop instead. A same-foreground
    /// blip (`.active → .inactive → .active`, e.g. Control Center) never
    /// sets it.
    @State private var pendingForegroundReconcile = false
    @AccessibilityFocusState private var launchFailureFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var launchFailureAccessibilityEffects = LaunchFailureAccessibilityEffects.live

    var body: some View {
        ZStack {
            switch launch.phase {
            case .loading:
                SplashView()
                    .transition(.opacity)
            case .onboarding:
                OnboardingScreen(
                    showsPermissionAction: !launch.onboardingCompletionPending,
                    isBusy: launch.isImporting,
                    statusMessage: launch.statusMessage,
                    canContinueWithoutContacts: launch.canContinueWithoutContacts,
                    continueActionTitle: launch.onboardingCompletionPending
                        ? "Finish setup"
                        : "Continue without contacts",
                    onAllow: {
                        Task { await launch.requestContactsAndImport() }
                    },
                    onContinueWithoutContacts: {
                        Task { await launch.continueWithoutContacts() }
                    },
                    onWhyWeAsk: { showsTransparency = true }
                )
                .transition(.opacity)
            case .ready:
                if let runtime = launch.runtime {
                    RegardsTabRoot(
                        runtime: runtime,
                        reconciliationGeneration: launch.reconciliationCount
                    )
                    .transition(.opacity)
                } else {
                    launchFailure
                        .transition(.opacity)
                }
            case .failed:
                launchFailure
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: launch.phase)
        .task {
            await launch.start()
        }
        // Re-reconcile Contacts every foreground (ARCHITECTURE.md §7);
        // launch itself already covers the first appearance. `.active`
        // reached without the latch set is a same-foreground blip; plain
        // `.inactive` is just the hop the latch survives.
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                pendingForegroundReconcile = true
            case .active where pendingForegroundReconcile:
                pendingForegroundReconcile = false
                Task { await launch.handleSceneActivation() }
            default:
                break
            }
        }
        .onChange(of: launchFailureMessage, initial: true) { _, message in
            launchFailureEffectGeneration &+= 1
            let effectGeneration = launchFailureEffectGeneration
            guard let message else {
                launchFailureFocused = false
                return
            }
            let effects = launchFailureAccessibilityEffects
            Task { @MainActor in
                await effects.yieldControl()
                guard launchFailureEffectGeneration == effectGeneration else { return }
                effects.announce(message)
                await effects.yieldControl()
                guard launchFailureEffectGeneration == effectGeneration else { return }
                launchFailureFocused = true
                effects.didFocusRetry()
            }
        }
        .sheet(isPresented: $showsTransparency) {
            NavigationStack {
                TransparencyScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsTransparency = false }
                        }
                    }
            }
        }
    }

    private var launchFailure: some View {
        ContentUnavailableView {
            Label("Unable to open Regards", systemImage: "exclamationmark.triangle")
        } description: {
            Text(launch.statusMessage ?? "Regards couldn't open its local data. Try again.")
        } actions: {
            Button {
                Task { await launch.retry() }
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .foregroundStyle(RegardsDS.background)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .background(RegardsDS.accentInk, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityFocused($launchFailureFocused)
            .accessibilityIdentifier("launch.try-again")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RegardsDS.background.ignoresSafeArea())
        .accessibilityIdentifier("launch.failure")
    }

    private var launchFailureMessage: String? {
        guard launch.phase == .failed || (launch.phase == .ready && launch.runtime == nil) else {
            return nil
        }
        return launch.statusMessage ?? "Regards couldn't open its local data. Try again."
    }
}

struct LaunchFailureAccessibilityEffects {
    let announce: @MainActor (String) -> Void
    let didFocusRetry: @MainActor () -> Void
    let yieldControl: @MainActor () async -> Void

    init(
        announce: @escaping @MainActor (String) -> Void,
        didFocusRetry: @escaping @MainActor () -> Void,
        yieldControl: @escaping @MainActor () async -> Void = { await Task.yield() }
    ) {
        self.announce = announce
        self.didFocusRetry = didFocusRetry
        self.yieldControl = yieldControl
    }

    static let live = LaunchFailureAccessibilityEffects(
        announce: { AccessibilityNotification.Announcement($0).post() },
        didFocusRetry: {}
    )
}

/// Splash shown while the production database, runtime, and profile load.
struct SplashView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var wordmarkWidth: CGFloat = 240

    var body: some View {
        ZStack {
            RegardsDS.background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                Image("LaunchWordmark")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: wordmarkWidth)
                    .accessibilityHidden(true)
                Spacer()
                Text("© 2026 Considerate Software LLC")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(RegardsDS.muted)
                    .padding(.bottom, 24)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Regards. Loading.")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("launch.root")
    }
}

/// The tab-bar root. Every feature screen reaches users through one of the
/// four tabs. Each tab wraps its content in a `NavigationStack` so pushes
/// (Contact Detail, Edit, Transparency, …) stay local to the tab.
struct RegardsTabRoot: View {
    let runtime: AppRuntime
    /// Threaded straight through from `AppLaunchCoordinator.reconciliationCount`
    /// via `RootView` — see `AllContactsScreen.reconciliationGeneration`'s
    /// doc comment for why this exists instead of a `scenePhase` hook.
    let reconciliationGeneration: Int
    @State private var navigation = RegardsNavigationState()
    @State private var overdueVM: OverdueViewModel
    @State private var upcomingVM: UpcomingViewModel
    @State private var mergeDuplicatesVM: MergeDuplicatesViewModel
    @State private var intentRouter = RegardsIntentRouter.shared
    @Namespace private var overdueContactTransition
    @Namespace private var upcomingContactTransition
    @Namespace private var contactsContactTransition

    init(runtime: AppRuntime, reconciliationGeneration: Int = 0) {
        self.runtime = runtime
        self.reconciliationGeneration = reconciliationGeneration
        self._overdueVM = State(
            initialValue: Self.makeOverdueViewModel(runtime: runtime)
        )
        self._upcomingVM = State(
            initialValue: Self.makeUpcomingViewModel(runtime: runtime)
        )
        self._mergeDuplicatesVM = State(
            initialValue: MergeDuplicatesViewModel(contacts: runtime.environment.contacts)
        )
    }

    // MARK: - View model composition
    //
    // These factories each have one production call site, below the repo's
    // three-call-site bar for extracting a helper. They stay anyway, and the
    // justification is specific rather than stylistic: composition is the
    // thing being tested. `AppRuntimeTests` calls every one of them to prove
    // the production runtime injects the persisted window (R9a), shares one
    // clock across screens, and never retains mock timing — assertions that
    // are impossible to make against a view model constructed inline inside a
    // `State` initializer, because no test can reach it. Inlining these would
    // trade a named seam for silently untested composition, which is how R9
    // survived as long as it did. Each factory is also the single place a new
    // dependency has to be threaded, so a missed injection fails in one
    // place instead of two.

    @MainActor
    static func makeOverdueViewModel(runtime: AppRuntime) -> OverdueViewModel {
        OverdueViewModel(
            contacts: runtime.environment.contacts,
            interactions: runtime.environment.interactions,
            reminders: runtime.environment.reminders,
            scheduler: runtime.scheduler,
            clock: runtime.clock,
            calendar: runtime.userCalendar
        )
    }

    @MainActor
    static func makeUpcomingViewModel(runtime: AppRuntime) -> UpcomingViewModel {
        UpcomingViewModel(
            contacts: runtime.environment.contacts,
            reminders: runtime.environment.reminders,
            scheduler: runtime.scheduler,
            interactions: runtime.environment.interactions,
            window: runtime.window,
            clock: runtime.clock
        )
    }

    @MainActor
    static func makeAllContactsViewModel(runtime: AppRuntime) -> AllContactsViewModel {
        AllContactsViewModel(
            contacts: runtime.environment.contacts,
            clock: runtime.clock
        )
    }

    @MainActor
    static func makeContactDetailViewModel(
        contactId: UUID,
        runtime: AppRuntime
    ) -> ContactDetailViewModel {
        ContactDetailViewModel(
            contactId: contactId,
            contacts: runtime.environment.contacts,
            interactionsRepo: runtime.environment.interactions,
            scheduler: runtime.scheduler,
            clock: runtime.clock,
            calendar: runtime.userCalendar
        )
    }

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        .modifier(RegardsTabBarBehavior())
        // `accentInk` (darker warm) rather than `accent` (lighter terracotta)
        // so tab-bar icon + label contrast passes AA against the tab bar's
        // translucent system surface — `accent` on that surface measures
        // ~3.4:1, below body-text AA. `accentInk` is ~8:1.
        .tint(RegardsDS.accentInk)
        .onChange(of: intentRouter.request) { _, request in
            handleIntentRequest(request)
        }
        // Kick off both VMs up-front so the cross-tab counters on the
        // segmented control (Overdue shows upcomingCount, Upcoming shows
        // overdueCount) are populated at launch — otherwise the opposite
        // tab's `.task` wouldn't fire until the user tapped it.
        .task {
            handleIntentRequest(intentRouter.request)
            async let overdueLoad: Void = overdueVM.load()
            async let upcomingLoad: Void = upcomingVM.load()
            _ = await (overdueLoad, upcomingLoad)
        }
        .accessibilityIdentifier("root.tabs")
    }

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView(selection: $navigation.selected) {
            Tab("Overdue", systemImage: "exclamationmark.circle", value: RegardsTab.overdue) {
                overdueRoot
            }

            Tab("Upcoming", systemImage: "calendar", value: RegardsTab.upcoming) {
                upcomingRoot
            }

            Tab(
                "Contacts",
                systemImage: "person.2",
                value: RegardsTab.contacts,
                role: .search
            ) {
                contactsRoot
            }

            Tab("Settings", systemImage: "gearshape", value: RegardsTab.settings) {
                settingsRoot
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    private var legacyTabView: some View {
        TabView(selection: $navigation.selected) {
            overdueRoot
                .tabItem { Label("Overdue", systemImage: "exclamationmark.circle") }
                .tag(RegardsTab.overdue)

            upcomingRoot
                .tabItem { Label("Upcoming", systemImage: "calendar") }
                .tag(RegardsTab.upcoming)

            contactsRoot
                .tabItem { Label("Contacts", systemImage: "person.2") }
                .tag(RegardsTab.contacts)

            settingsRoot
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(RegardsTab.settings)
        }
    }

    private var overdueRoot: some View {
        NavigationStack(path: $navigation.overduePath) {
            // No `onTapContact` any more (round 12): row tap previews the
            // channel action instead of pushing Contact Detail — see
            // `OverdueRow`'s doc comment. `navigationDestination` below is
            // kept, not removed: nothing pushes onto `overduePath` from
            // this screen today, but the destination itself costs nothing
            // to leave wired, and ripping it (plus the transition
            // namespace below) out is a separate call this round didn't
            // ask for — flagged in the round-12 report rather than done
            // unilaterally.
            OverdueScreen(
                viewModel: overdueVM,
                accessibilityEffects: .live,
                upcomingCount: upcomingVM.totalCount,
                onSwitchToUpcoming: { navigation.selected = .upcoming },
                rowActionAnnouncer: RowActionAnnouncer()
            )
            .navigationDestination(for: UUID.self) { contactId in
                contactDetail(for: contactId)
            }
        }
        .environment(\.regardsContactTransitionNamespace, overdueContactTransition)
    }

    private var upcomingRoot: some View {
        NavigationStack(path: $navigation.upcomingPath) {
            // See `overdueRoot`'s matching comment above — same reasoning.
            UpcomingScreen(
                viewModel: upcomingVM,
                accessibilityEffects: .live,
                overdueCount: overdueVM.overdueCount,
                onSwitchToOverdue: { navigation.selected = .overdue },
                rowActionAnnouncer: RowActionAnnouncer()
            )
            .navigationDestination(for: UUID.self) { contactId in
                contactDetail(for: contactId)
            }
        }
        .environment(\.regardsContactTransitionNamespace, upcomingContactTransition)
    }

    private var contactsRoot: some View {
        NavigationStack(path: $navigation.contactsPath) {
            AllContactsScreen(
                viewModel: Self.makeAllContactsViewModel(runtime: runtime),
                searchText: $navigation.contactsSearchText,
                reconciliationGeneration: reconciliationGeneration
            )
            .navigationDestination(for: UUID.self) { contactId in
                contactDetail(for: contactId)
            }
        }
        .environment(\.regardsContactTransitionNamespace, contactsContactTransition)
    }

    private var settingsRoot: some View {
        NavigationStack(path: $navigation.settingsPath) {
            SettingsScreen()
                .navigationDestination(for: RegardsSettingsRoute.self) { route in
                    settingsDestination(for: route)
                }
        }
    }

    private func handleIntentRequest(_ request: RegardsIntentRouter.Request?) {
        guard let request else { return }
        navigation.openRoot(request.tab)
        intentRouter.consume(request.id)
    }

    @ViewBuilder
    private func settingsDestination(for route: RegardsSettingsRoute) -> some View {
        switch route {
        case .reminderWindows:
            ReminderWindowsScreen()
        case .mergeDuplicates:
            MergeDuplicatesScreen(viewModel: mergeDuplicatesVM)
        case .transparency:
            TransparencyScreen()
        case .onboarding:
            OnboardingScreen(
                showsPermissionAction: false,
                onWhyWeAsk: {
                    navigation.settingsPath.append(RegardsSettingsRoute.transparency)
                }
            )
        }
    }

    /// Factory for a Contact Detail destination. A fresh VM is created per
    /// push so navigating two different contacts in a row shows the right
    /// data (relying on SwiftUI view identity alone would recycle the old
    /// VM).
    @ViewBuilder
    private func contactDetail(for contactId: UUID) -> some View {
        ContactDetailScreen(
            viewModel: Self.makeContactDetailViewModel(
                contactId: contactId,
                runtime: runtime
            ),
            accessibilityEffects: .live,
            rowActionAnnouncer: RowActionAnnouncer()
        )
    }
}

#Preview("Splash") {
    SplashView()
}

#Preview("Tab root") {
    RegardsTabRoot(runtime: .makeMock())
}
