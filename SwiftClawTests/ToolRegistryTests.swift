import Foundation
import Testing
@testable import SwiftClaw

struct ToolRegistryTests {
    @Test func availableToolsExcludeDisabledTools() {
        let registry = ToolRegistry(tools: [
            TestTool(name: "enabled"),
            TestTool(name: "disabled", isEnabled: false),
        ])

        #expect(registry.availableTools.map(\.name) == ["enabled"])
    }

    @Test func explicitToolsStillRequireExplicitEnable() {
        let registry = ToolRegistry(tools: [
            TestTool(name: "automatic"),
            TestTool(name: "explicit", requiresExplicitEnable: true),
        ])

        #expect(registry.availableTools.map(\.name) == ["automatic"])
        #expect(registry.availableTools(includingExplicitlyEnabled: true).map(\.name) == [
            "automatic",
            "explicit",
        ])
    }
}

private struct TestTool: Tool {
    let name: String
    var displayName: String { name }
    let description = "Test tool"
    let systemImage = "wrench"
    let parameters: [ToolParameter] = []
    var isConfigured = true
    var isEnabled = true
    var requiresExplicitEnable = false

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "ok"
    }
}
