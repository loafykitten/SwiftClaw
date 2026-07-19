import Foundation

/// Runs a quick, multi-search web investigation via ``ResearchEngine``.
///
/// Only offered to the model when the user explicitly toggles the search
/// button in the chat composer for a message.
struct InvestigateTool: Tool {
    let name = "investigate"
    let displayName = "Investigation"
    let description = """
        Run a quick, multi-search investigation for an in-chat question: a surface \
        search, parallel follow-up lines of inquiry, and a conversational report. \
        Use when the question needs cross-referencing beyond a single search but \
        does not need a standalone report. For deeper needs, the standalone \
        Research tab produces full cited, verified reports. When presenting the \
        result, keep the overview and key findings easy to scan and preserve every \
        [n] source citation. The investigation may take a minute or two.
        """
    let systemImage = "text.magnifyingglass"
    let requiresExplicitEnable = true

    let parameters = [
        ToolParameter(
            name: "topic",
            type: .string,
            description: "The topic or question to investigate.",
            isRequired: true
        ),
        ToolParameter(
            name: "focus",
            type: .string,
            description: "Optional angle to emphasize, e.g. \"recent developments\" or \"criticism\"."
        ),
    ]

    var isConfigured: Bool {
        let braveKey = Keychain.string(forKey: SettingsKeys.braveSearchAPIKey) ?? ""
        let clawModel = UserDefaults.standard.string(forKey: SettingsKeys.clawModel) ?? ""
        let swiftModel = UserDefaults.standard.string(forKey: SettingsKeys.swiftModel) ?? ""

        return !braveKey.isEmpty && !clawModel.isEmpty && !swiftModel.isEmpty
    }

    var isEnabled: Bool {
        SettingsStorage.isInvestigationEnabled()
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let topic = arguments["topic"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !topic.isEmpty else {
            throw ToolError.missingArgument("topic")
        }

        let focus = arguments["focus"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let activityScope = ToolActivityContext.currentScope

        await MainActor.run {
            ToolActivityMonitor.shared.setStatusLabel("Investigating", for: activityScope)
        }

        defer {
            Task { @MainActor in
                ToolActivityMonitor.shared.setStatusLabel(nil, for: activityScope)
            }
        }

        return try await ResearchEngine(configuration: .investigation()).investigate(
            topic: topic,
            focus: (focus?.isEmpty ?? true) ? nil : focus
        )
    }
}
