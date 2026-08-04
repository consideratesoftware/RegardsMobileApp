import Foundation
import SwiftUI

@main
struct RegardsApp: App {
    // Phase 0 runs against MockRepositories. Phase 1 swaps in GRDBRepositories
    // here without touching any view code.
    private let env: AppEnvironment = {
#if DEBUG
        AppEnvironment.makeMock(
            includeDuplicateFixture:
                ProcessInfo.processInfo.environment["REGARDS_UI_TEST_DUPLICATE_FIXTURE"] == "1"
        )
#else
        AppEnvironment.makeMock()
#endif
    }()

    var body: some Scene {
        WindowGroup {
            RootView(env: env)
                .modifier(UITestDynamicTypeOverride())
        }
    }
}

/// Gives UI tests a deterministic way to exercise accessibility layouts
/// without changing the shared Simulator's system settings.
private struct UITestDynamicTypeOverride: ViewModifier {
#if DEBUG
    private let requestedSize = ProcessInfo.processInfo.environment["REGARDS_UI_TEST_DYNAMIC_TYPE"]
#endif

    @ViewBuilder
    func body(content: Content) -> some View {
#if DEBUG
        if requestedSize == "accessibility5" {
            content.environment(\.dynamicTypeSize, .accessibility5)
        } else {
            content
        }
#else
        content
#endif
    }
}

/// The first SwiftUI view the user sees. Shows the splash for a brief brand
/// moment, then crossfades into the real tab root once `.task` fires.
struct RootView: View {
    let env: AppEnvironment
    @State private var isReady = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isReady {
                RegardsTabRoot(env: env)
                    .transition(.opacity)
            } else {
                SplashView()
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: isReady)
        .task {
            // Give the splash a single beat before cutting to content —
            // enough to feel intentional, short enough not to feel slow.
            try? await Task.sleep(nanoseconds: 600_000_000)
            isReady = true
        }
    }
}

/// Splash shown during the app's first render pass. Phase 1 will drive the
/// transition off actual loading completion; Phase 0 just waits briefly.
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
    let env: AppEnvironment
    @State private var navigation = RegardsNavigationState()
    @State private var overdueVM: OverdueViewModel
    @State private var upcomingVM: UpcomingViewModel
    @State private var mergeDuplicatesVM: MergeDuplicatesViewModel
    @State private var intentRouter = RegardsIntentRouter.shared
    @Namespace private var overdueContactTransition
    @Namespace private var upcomingContactTransition
    @Namespace private var contactsContactTransition

    init(env: AppEnvironment) {
        self.env = env
        self._overdueVM = State(initialValue: OverdueViewModel(contacts: env.contacts))
        self._upcomingVM = State(
            initialValue: UpcomingViewModel(
                contacts: env.contacts,
                reminders: env.reminders
            )
        )
        self._mergeDuplicatesVM = State(
            initialValue: MergeDuplicatesViewModel(contacts: env.contacts)
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
            OverdueScreen(
                viewModel: overdueVM,
                upcomingCount: upcomingVM.totalCount,
                onTapContact: { contactId in navigation.overduePath.append(contactId) },
                onSwitchToUpcoming: { navigation.selected = .upcoming }
            )
            .navigationDestination(for: UUID.self) { contactId in
                contactDetail(for: contactId)
            }
        }
        .environment(\.regardsContactTransitionNamespace, overdueContactTransition)
    }

    private var upcomingRoot: some View {
        NavigationStack(path: $navigation.upcomingPath) {
            UpcomingScreen(
                viewModel: upcomingVM,
                overdueCount: overdueVM.overdueCount,
                onTapContact: { contactId in navigation.upcomingPath.append(contactId) },
                onSwitchToOverdue: { navigation.selected = .overdue }
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
                env: env,
                searchText: $navigation.contactsSearchText
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
            OnboardingScreen()
        }
    }

    /// Factory for a Contact Detail destination. A fresh VM is created per
    /// push so navigating two different contacts in a row shows the right
    /// data (relying on SwiftUI view identity alone would recycle the old
    /// VM).
    @ViewBuilder
    private func contactDetail(for contactId: UUID) -> some View {
        ContactDetailScreen(
            contactId: contactId,
            contacts: env.contacts,
            interactionsRepo: env.interactions
        )
    }
}

private struct RegardsTabBarBehavior: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

#Preview("Splash") {
    SplashView()
}

#Preview("Tab root") {
    RegardsTabRoot(env: AppEnvironment.makeMock())
}
