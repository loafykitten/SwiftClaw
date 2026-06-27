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

    /// Email review tools are system-only: they're constructed per-pass against
    /// a scoped `ToolRegistry(tools:)` at the call site so the assistant can't
    /// invoke them during a normal user chat. `ToolRegistry.shared` (offered
    /// on every chat) must NOT register any of them — that's the one
    /// regression class the static strict-concurrency checker can't catch on
    /// its own.
    @Test func systemOnlyEmailReviewToolsAreNotOnSharedRegistry() {
        let sharedToolNames = Set(ToolRegistry.shared.tools.map(\.name))
        let systemOnlyTools: Set<String> = [
            "fetch_inbox_emails",
            "notify_user_about_emails",
            "add_email_note",
            "set_email_flag",
            "refresh_email_review",
        ]
        #expect(sharedToolNames.isDisjoint(with: systemOnlyTools))
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
