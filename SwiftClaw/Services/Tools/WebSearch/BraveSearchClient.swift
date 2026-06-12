import Foundation

/// Minimal client for the Brave Search API.
///
/// https://api-dashboard.search.brave.com/app/documentation/web-search
struct BraveSearchClient: Sendable {
    struct Result: Sendable {
        let title: String
        let url: String
        let description: String
        let age: String?
    }

    enum ClientError: LocalizedError {
        case missingAPIKey
        case badResponse(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Brave Search API key is not set. Add it in Settings → Providers."
            case .badResponse(let statusCode, let body):
                "Brave Search returned HTTP \(statusCode): \(body)"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.search.brave.com/res/v1/web/search")!

    let apiKey: String

    static func fromSettings() -> BraveSearchClient {
        BraveSearchClient(apiKey: Keychain.string(forKey: SettingsKeys.braveSearchAPIKey) ?? "")
    }

    func search(query: String, count: Int = 5) async throws -> [Result] {
        guard !apiKey.isEmpty else {
            throw ClientError.missingAPIKey
        }

        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(min(max(count, 1), 20))),
            URLQueryItem(name: "text_decorations", value: "false"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw ClientError.badResponse(statusCode: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)

        return (decoded.web?.results ?? []).map { result in
            Result(
                title: result.title,
                url: result.url,
                description: result.description ?? "",
                age: result.age
            )
        }
    }
}

// MARK: - Response models (only the fields we use)

private struct SearchResponse: Decodable {
    let web: WebResults?
}

private struct WebResults: Decodable {
    let results: [WebResult]
}

private struct WebResult: Decodable {
    let title: String
    let url: String
    let description: String?
    let age: String?
}
