import Foundation
import OpenAI
import Testing
@testable import SwiftClaw

@Suite("Inference tool loop", .serialized)
struct InferenceToolLoopTests {
    private typealias ToolCall = ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam

    @Test func runsEveryCallInOrderWhenNotCancelled() async throws {
        let log = LockedValue<[String]>([])
        let tools: [any SwiftClaw.Tool] = [
            RecordingTool(name: "first", log: log),
            RecordingTool(name: "second", log: log),
        ]

        let messages = try await InferenceService.toolResultMessages(
            for: [call("first"), call("second")],
            tools: tools
        )

        #expect(messages.count == 2)
        #expect(log.value == ["first", "second"])
    }

    /// A tool that throws cancellation must abort the round, not hand the
    /// model an error string and carry on to the next call.
    @Test func cancellationThrownByToolStopsLaterCalls() async throws {
        let log = LockedValue<[String]>([])
        let tools: [any SwiftClaw.Tool] = [
            RecordingTool(name: "first", log: log, behavior: .cancelAndThrow),
            RecordingTool(name: "second", log: log),
        ]

        let task = Task {
            try await InferenceService.toolResultMessages(
                for: [call("first"), call("second")],
                tools: tools
            )
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(log.value == ["first"])
    }

    /// Cancellation that lands while a tool is running (and the tool still
    /// returns normally) must also stop the remaining calls.
    @Test func cancellationDuringToolThatReturnsStopsLaterCalls() async throws {
        let log = LockedValue<[String]>([])
        let tools: [any SwiftClaw.Tool] = [
            RecordingTool(name: "first", log: log, behavior: .cancelAndReturn),
            RecordingTool(name: "second", log: log),
        ]

        let task = Task {
            try await InferenceService.toolResultMessages(
                for: [call("first"), call("second")],
                tools: tools
            )
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(log.value == ["first"])
    }

    @Test func ordinaryToolErrorsAreReportedToTheModel() async throws {
        let log = LockedValue<[String]>([])
        let tools: [any SwiftClaw.Tool] = [
            RecordingTool(name: "first", log: log, behavior: .fail),
            RecordingTool(name: "second", log: log),
        ]

        let messages = try await InferenceService.toolResultMessages(
            for: [call("first"), call("second")],
            tools: tools
        )

        #expect(messages.count == 2)
        #expect(log.value == ["first", "second"])
    }

    private func call(_ name: String) -> ToolCall {
        ToolCall(id: "call-\(name)", function: .init(arguments: "{}", name: name))
    }
}

private struct RecordingTool: SwiftClaw.Tool {
    enum Behavior: Sendable {
        case succeed
        case fail
        case cancelAndThrow
        case cancelAndReturn
    }

    let name: String
    let log: LockedValue<[String]>
    var behavior: Behavior = .succeed

    var displayName: String { name }
    let description = "Records that it ran"
    let systemImage = "wrench"
    let parameters: [ToolParameter] = []
    let isConfigured = true
    let isEnabled = true
    let requiresExplicitEnable = false

    func execute(arguments: [String: JSONValue]) async throws -> String {
        log.update { $0.append(name) }
        switch behavior {
        case .succeed:
            return "ok"
        case .fail:
            throw ToolError.executionFailed("boom")
        case .cancelAndThrow:
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        case .cancelAndReturn:
            withUnsafeCurrentTask { $0?.cancel() }
            return "ok"
        }
    }
}
