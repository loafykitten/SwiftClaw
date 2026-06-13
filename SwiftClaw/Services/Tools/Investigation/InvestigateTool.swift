import Foundation

/// Runs a deep, multi-pass web investigation via ``InvestigationEngine``.
///
/// Only offered to the model when the user explicitly toggles the search
/// button in the chat composer for a message.
struct InvestigateTool: Tool {
    let name = "investigate"
    let displayName = "Investigation"
    let description = """
        Run a deep, multi-pass web investigation of a topic: a surface search, \
        follow-up lines of inquiry investigated in parallel, and a synthesized \
        report (Overview, Key Findings, Deeper Findings, Sources). Use when the \
        question benefits from depth and cross-referencing rather than a single \
        quick search. When presenting the report, preserve its structure: the \
        broad overview and key findings first, then the deeper findings, keeping \
        the [n] source citations. The investigation may take a minute or two.
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

        return try await InvestigationEngine().investigate(
            topic: topic,
            focus: (focus?.isEmpty ?? true) ? nil : focus
        )
    }
}
