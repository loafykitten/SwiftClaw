import Foundation
import OpenAI

/// Bridges the app's `Tool` protocol to the OpenAI function-calling API.
extension Tool {
    /// The tool encoded as an OpenAI-compatible function definition.
    func chatToolParam() throws -> ChatQuery.ChatCompletionToolParam {
        // JSONValue and JSONSchema are both plain Codable JSON representations,
        // so a round-trip through Data converts between them.
        let data = try JSONEncoder().encode(parametersSchema)
        let schema = try JSONDecoder().decode(JSONSchema.self, from: data)

        return ChatQuery.ChatCompletionToolParam(
            function: .init(
                name: name,
                description: description,
                parameters: schema
            )
        )
    }
}
