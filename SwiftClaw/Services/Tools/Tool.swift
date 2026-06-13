import Foundation

/// A loosely typed JSON value used for tool arguments and schemas.
enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        numberValue.map(Int.init)
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

/// Describes a single parameter of a tool, mirroring a JSON Schema property.
struct ToolParameter: Sendable, Hashable {
    enum ParameterType: String, Sendable {
        case string
        case number
        case integer
        case boolean
    }

    let name: String
    let type: ParameterType
    let description: String
    let isRequired: Bool

    init(name: String, type: ParameterType, description: String, isRequired: Bool = false) {
        self.name = name
        self.type = type
        self.description = description
        self.isRequired = isRequired
    }
}

enum ToolError: LocalizedError {
    case notConfigured(toolName: String, reason: String)
    case missingArgument(String)
    case invalidArguments(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let toolName, let reason):
            "\(toolName) is not configured: \(reason)"
        case .missingArgument(let name):
            "Missing required argument \"\(name)\"."
        case .invalidArguments(let detail):
            "Invalid tool arguments: \(detail)"
        case .executionFailed(let detail):
            "Tool execution failed: \(detail)"
        }
    }
}

/// A capability the assistant can invoke during a conversation.
///
/// Tools take JSON arguments (as produced by a model's tool call) and return
/// a plain-text result that is fed back into the model's context, so results
/// should be kept compact.
protocol Tool: Sendable {
    /// Unique machine name, e.g. "web_search".
    var name: String { get }

    /// Human-readable display name, e.g. "Web Search".
    var displayName: String { get }

    /// Description shown to the model so it knows when to use the tool.
    var description: String { get }

    /// SF Symbol used when displaying the tool in the UI.
    var systemImage: String { get }

    var parameters: [ToolParameter] { get }

    /// Whether the tool has everything it needs (API keys, etc.) to run.
    var isConfigured: Bool { get }

    /// Whether the user currently allows this tool to be offered.
    var isEnabled: Bool { get }

    /// Whether the tool is only offered when the user explicitly enables it
    /// for a message (e.g. via a composer toggle), rather than on every request.
    var requiresExplicitEnable: Bool { get }

    func execute(arguments: [String: JSONValue]) async throws -> String
}

extension Tool {
    var isEnabled: Bool { true }

    var requiresExplicitEnable: Bool { false }
}

extension Tool {
    /// JSON Schema for the tool's parameters, in the shape expected by
    /// OpenAI-compatible function-calling APIs.
    var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(
                Dictionary(uniqueKeysWithValues: parameters.map { parameter in
                    (parameter.name, JSONValue.object([
                        "type": .string(parameter.type.rawValue),
                        "description": .string(parameter.description),
                    ]))
                })
            ),
            "required": .array(parameters.filter(\.isRequired).map { .string($0.name) }),
        ])
    }

    /// Decodes a model-produced JSON argument string and runs the tool.
    func execute(argumentsJSON: String) async throws -> String {
        let arguments: [String: JSONValue]
        do {
            arguments = try JSONDecoder().decode(
                [String: JSONValue].self,
                from: Data(argumentsJSON.utf8)
            )
        } catch {
            throw ToolError.invalidArguments(error.localizedDescription)
        }

        return try await execute(arguments: arguments)
    }
}
