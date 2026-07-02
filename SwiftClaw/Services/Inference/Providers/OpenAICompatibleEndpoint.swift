import Foundation
import OpenAI
import os

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

    private static let logger = AppLog.make("InferenceService")

    private let client: OpenAI
    private let responseRecorder: OpenAICompatibleResponseRecorder

    init(providerID: InferenceProviderID, endpoint: OpenAICompatibleEndpoint, apiKey: String) {
        let responseRecorder = OpenAICompatibleResponseRecorder()
        var middlewares = endpoint.makeMiddlewares()
        middlewares.append(OpenAICompatibleResponseCaptureMiddleware(recorder: responseRecorder))

        self.providerID = providerID
        self.responseRecorder = responseRecorder
        self.client = OpenAI(
            configuration: endpoint.makeConfiguration(apiKey: apiKey),
            middlewares: middlewares
        )
    }

    func complete(query: ChatQuery) async throws -> ChatResult {
        responseRecorder.clear()
        do {
            return try await client.chats(query: query)
        } catch {
            logCapturedResponse(for: query, error: error)
            throw error
        }
    }

    func streamCompletion(query: ChatQuery) -> AsyncThrowingStream<ChatStreamResult, Error> {
        client.chatsStream(query: query)
    }

    private func logCapturedResponse(for query: ChatQuery, error: Error) {
        guard let response = responseRecorder.snapshot() else {
            Self.logger.error("""
                OpenAI-compatible response decode failed for provider \
                \(providerID.rawValue, privacy: .public) model \(query.model, privacy: .public), \
                but no HTTP response body was captured. Error: \
                \(Self.describe(error), privacy: .public)
                """)
            return
        }

        Self.logger.error("""
            OpenAI-compatible response decode failed for provider \
            \(providerID.rawValue, privacy: .public) model \(query.model, privacy: .public). \
            Error: \(Self.describe(error), privacy: .public). \
            HTTP \(response.statusDescription, privacy: .public) \
            \(response.method, privacy: .public) \(response.url, privacy: .public). \
            content-type: \(response.contentType ?? "nil", privacy: .public); \
            bytes: \(response.bodyByteCount, privacy: .public); \
            response id: \(response.responseID ?? "nil", privacy: .public); \
            response model: \(response.responseModel ?? "nil", privacy: .public); \
            raw service_tier: \(response.serviceTier ?? "nil", privacy: .public); \
            headers: \(response.headersSummary, privacy: .public); \
            body preview: \(response.bodyPreview, privacy: .public)
            """)
    }

    private static func describe(_ error: Error) -> String {
        guard case let DecodingError.dataCorrupted(context) = error else {
            return String(describing: error)
        }

        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        let renderedPath = path.isEmpty ? "<root>" : path
        return """
            DecodingError.dataCorrupted(path: \(renderedPath), \
            debug: \(context.debugDescription))
            """
    }
}

private final class OpenAICompatibleResponseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var latestResponse: OpenAICompatibleCapturedResponse?

    func clear() {
        lock.lock()
        latestResponse = nil
        lock.unlock()
    }

    func record(response: URLResponse?, request: URLRequest, data: Data?) {
        let captured = OpenAICompatibleCapturedResponse(
            response: response,
            request: request,
            data: data
        )

        lock.lock()
        latestResponse = captured
        lock.unlock()
    }

    func snapshot() -> OpenAICompatibleCapturedResponse? {
        lock.lock()
        defer { lock.unlock() }
        return latestResponse
    }
}

private struct OpenAICompatibleResponseCaptureMiddleware: OpenAIMiddleware {
    let recorder: OpenAICompatibleResponseRecorder

    func intercept(
        response: URLResponse?,
        request: URLRequest,
        data: Data?
    ) -> (response: URLResponse?, data: Data?) {
        recorder.record(response: response, request: request, data: data)
        return (response, Self.removingServiceTier(from: data))
    }

    private static func removingServiceTier(from data: Data?) -> Data? {
        guard let data,
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.contains("service_tier") else {
            return data
        }

        object.removeValue(forKey: "service_tier")
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }
}

private struct OpenAICompatibleCapturedResponse: Sendable {
    private static let previewLimit = 4_096

    let method: String
    let url: String
    let statusCode: Int?
    let contentType: String?
    let headersSummary: String
    let bodyByteCount: Int
    let bodyPreview: String
    let responseID: String?
    let responseModel: String?
    let serviceTier: String?

    init(response: URLResponse?, request: URLRequest, data: Data?) {
        let httpResponse = response as? HTTPURLResponse
        self.method = request.httpMethod ?? "UNKNOWN"
        self.url = request.url?.absoluteString ?? "nil"
        self.statusCode = httpResponse?.statusCode
        self.contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type")
            ?? response?.mimeType
        self.headersSummary = Self.headerSummary(from: httpResponse)
        self.bodyByteCount = data?.count ?? 0
        self.bodyPreview = Self.bodyPreview(from: data)

        let fields = Self.fields(from: data)
        self.responseID = fields["id"]
        self.responseModel = fields["model"]
        self.serviceTier = fields["service_tier"]
    }

    var statusDescription: String {
        guard let statusCode else { return "status nil" }
        return "\(statusCode)"
    }

    private static func headerSummary(from response: HTTPURLResponse?) -> String {
        guard let response else { return "nil" }

        return response.allHeaderFields
            .map { key, value in "\(key): \(value)" }
            .sorted()
            .joined(separator: "; ")
    }

    private static func bodyPreview(from data: Data?) -> String {
        guard let data, !data.isEmpty else { return "<empty>" }

        let prefix = Data(data.prefix(previewLimit))
        let decoded = String(data: prefix, encoding: .utf8)
            ?? "<non-UTF-8 body prefix: \(prefix.count) bytes>"

        guard data.count > previewLimit else { return decoded }
        return "\(decoded)... <truncated \(data.count - previewLimit) bytes>"
    }

    private static func fields(from data: Data?) -> [String: String] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var fields: [String: String] = [:]
        for key in ["id", "model", "service_tier"] {
            if let value = object[key] {
                fields[key] = String(describing: value)
            }
        }
        return fields
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
