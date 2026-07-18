import Foundation

/// Central registry of all tools available to the assistant.
struct ToolRegistry: Sendable {
    static let shared = ToolRegistry(tools: [
        WebSearchTool(),
        InvestigateTool(),
        SearchNotesTool(),
        ReadNoteTool(),
        SearchMemoryTool(),
        OpenMemoryCollectionTool(),
    ])

    let tools: [any Tool]

    init(tools: [any Tool]) {
        self.tools = tools
    }

    func tool(named name: String) -> (any Tool)? {
        tools.first { $0.name == name }
    }

    /// Tools that are configured and offered to the model on every request.
    var availableTools: [any Tool] {
        availableTools(includingExplicitlyEnabled: false)
    }

    /// Configured tools, optionally including those gated behind an explicit
    /// per-message user toggle (like Investigation).
    func availableTools(includingExplicitlyEnabled: Bool) -> [any Tool] {
        tools.filter { tool in
            tool.isConfigured
                && tool.isEnabled
                && (includingExplicitlyEnabled || !tool.requiresExplicitEnable)
        }
    }

    /// Looks up a tool by name and executes it with model-produced JSON arguments.
    func execute(toolNamed name: String, argumentsJSON: String) async throws -> String {
        guard let tool = tool(named: name) else {
            throw ToolError.executionFailed("Unknown tool \"\(name)\".")
        }

        return try await tool.execute(argumentsJSON: argumentsJSON)
    }
}
