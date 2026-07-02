import Foundation
import OpenAI

struct OpenAICompatibleEndpoint: Sendable, Equatable {
    enum AuthHeaderStyle: Sendable, Equatable {
        /// Uses `OpenAI.Configuration(token:)` to preserve the SDK's current wire behavior.
        case openAIConfigurationToken
        case bearerToken
        case apiKeyHeader(name: String)
    }

    struct QueryItem: Sendable, Equatable {
        let name: String
        let value: String?

        static func apiVersion(_ value: String) -> QueryItem {
            QueryItem(name: "api-version", value: value)
        }
    }

    // Investigation runs and slower local models routinely outlive the SDK's 60s default.
    static let timeoutInterval: TimeInterval = 300

    let host: String
    let basePath: String
    let scheme: String
    let port: Int
    let authHeaderStyle: AuthHeaderStyle
    let extraHeaders: [String: String]
    let queryItems: [QueryItem]

    init(
        host: String,
        basePath: String,
        scheme: String = "https",
        port: Int = 443,
        authHeaderStyle: AuthHeaderStyle = .openAIConfigurationToken,
        extraHeaders: [String: String] = [:],
        queryItems: [QueryItem] = []
    ) {
        self.host = host
        self.basePath = basePath
        self.scheme = scheme
        self.port = port
        self.authHeaderStyle = authHeaderStyle
        self.extraHeaders = extraHeaders
        self.queryItems = queryItems
    }

    func makeConfiguration(apiKey: String) -> OpenAI.Configuration {
        var token: String?
        var customHeaders: [String: String] = [:]

        switch authHeaderStyle {
        case .openAIConfigurationToken:
            token = apiKey
        case .bearerToken:
            customHeaders["Authorization"] = "Bearer \(apiKey)"
        case .apiKeyHeader(let name):
            customHeaders[name] = apiKey
        }

        for (name, value) in extraHeaders {
            customHeaders[name] = value
        }

        return OpenAI.Configuration(
            token: token,
            host: host,
            port: port,
            scheme: scheme,
            basePath: basePath,
            timeoutInterval: Self.timeoutInterval,
            customHeaders: customHeaders,
            // OpenAI-compatible providers commonly omit fields the strict decoder treats as required.
            parsingOptions: .relaxed
        )
    }

    func makeMiddlewares() -> [any OpenAIMiddleware] {
        guard !queryItems.isEmpty else {
            return []
        }

        return [OpenAICompatibleEndpointQueryMiddleware(queryItems: queryItems)]
    }
}

struct OpenAICompatibleClient: Sendable {
    let providerID: InferenceProviderID

    private let client: OpenAI

    init(providerID: InferenceProviderID, endpoint: OpenAICompatibleEndpoint, apiKey: String) {
        self.providerID = providerID
        self.client = OpenAI(
            configuration: endpoint.makeConfiguration(apiKey: apiKey),
            middlewares: endpoint.makeMiddlewares()
        )
    }

    func complete(query: ChatQuery) async throws -> ChatResult {
        try await client.chats(query: query)
    }

    func streamCompletion(query: ChatQuery) -> AsyncThrowingStream<ChatStreamResult, Error> {
        client.chatsStream(query: query)
    }
}

private struct OpenAICompatibleEndpointQueryMiddleware: OpenAIMiddleware {
    let queryItems: [OpenAICompatibleEndpoint.QueryItem]

    func intercept(request: URLRequest) -> URLRequest {
        guard !queryItems.isEmpty,
              let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return request
        }

        var request = request
        let endpointItems = queryItems.map { URLQueryItem(name: $0.name, value: $0.value) }
        components.queryItems = (components.queryItems ?? []) + endpointItems

        if let url = components.url {
            request.url = url
        }

        return request
    }
}
