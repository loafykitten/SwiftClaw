import Foundation

/// Central registry of all tools available to the assistant.
struct ToolRegistry: Sendable {
    static let shared = ToolRegistry(tools: [
        WebSearchTool(),
    ])

    let tools: [any Tool]

    init(tools: [any Tool]) {
        self.tools = tools
    }

    func tool(named name: String) -> (any Tool)? {
        tools.first { $0.name == name }
    }

    /// Tools that are currently configured and ready to run.
    var availableTools: [any Tool] {
        tools.filter(\.isConfigured)
    }

    /// Looks up a tool by name and executes it with model-produced JSON arguments.
    func execute(toolNamed name: String, argumentsJSON: String) async throws -> String {
        guard let tool = tool(named: name) else {
            throw ToolError.executionFailed("Unknown tool \"\(name)\".")
        }

        return try await tool.execute(argumentsJSON: argumentsJSON)
    }
}
