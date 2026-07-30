import AppIntents

/// App Shortcuts are an iOS 26 showcase surface. Earlier supported systems
/// retain the complete in-app experience without registering this integration.
@available(iOS 26.0, *)
extension RegardsTab: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Regards section"

    static let caseDisplayRepresentations: [RegardsTab: DisplayRepresentation] = [
        .overdue: "Overdue",
        .upcoming: "Upcoming",
        .contacts: "Contacts",
        .settings: "Settings",
    ]
}

@available(iOS 26.0, *)
struct OpenRegardsSectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Regards section"
    static let description = IntentDescription(
        "Open Regards directly to Overdue, Upcoming, Contacts, or Settings."
    )
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Section")
    var section: RegardsTab

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$section)")
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            RegardsIntentRouter.shared.submit(section)
        }
        return .result()
    }
}

@available(iOS 26.0, *)
struct RegardsAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenRegardsSectionIntent(),
            phrases: [
                "Open \(\.$section) in \(.applicationName)",
                "Show \(\.$section) in \(.applicationName)",
            ],
            shortTitle: "Open Regards",
            systemImageName: "heart.text.square"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
