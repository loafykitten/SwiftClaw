import Foundation
import PDFKit
import Synchronization

/// The bounded, decoded result of fetching one research source.
nonisolated struct FetchedPage: Sendable, Equatable {
    let finalURL: URL
    let mimeType: String
    let bodyText: String
}

nonisolated enum PageFetchError: LocalizedError, Sendable, Equatable {
    case unsupportedContentType(String?)
    case httpStatus(Int)
    case tooLarge(maxBytes: Int)
    case timeout
    case invalidResponse
    case invalidPDF
    case blockedDestination
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedContentType(let contentType):
            "Unsupported page content type: \(contentType ?? "missing")."
        case .httpStatus(let statusCode):
            "The page returned HTTP \(statusCode)."
        case .tooLarge(let maxBytes):
            "The page exceeded the \(maxBytes)-byte fetch limit."
        case .timeout:
            "The page request timed out."
        case .invalidResponse:
            "The page returned an invalid response."
        case .invalidPDF:
            "The fetched PDF could not be read."
        case .blockedDestination:
            "The page address points to a local or private network, or could not be resolved."
        case .network(let message):
            "The page request failed: \(message)"
        }
    }
}

/// Fetches bounded HTML, plain-text, and PDF research sources.
nonisolated struct PageFetcher: Sendable {
    static let requestTimeout: TimeInterval = 15

    private static let acceptedMIMETypes: Set<String> = [
        "text/html",
        "application/xhtml+xml",
        "text/plain",
        "application/pdf",
    ]

    /// Isolated from `URLSession.shared`: no cookies, credentials, or cache
    /// are shared with the rest of the app or carried between sources.
    static let isolatedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession
    private let resolveHost: FetchDestinationPolicy.HostResolver

    init(
        session: URLSession = PageFetcher.isolatedSession,
        resolveHost: @escaping FetchDestinationPolicy.HostResolver = FetchDestinationPolicy.systemResolver
    ) {
        self.session = session
        self.resolveHost = resolveHost
    }

    func fetch(url: URL, maxBytes: Int) async throws -> FetchedPage {
        guard maxBytes > 0 else {
            throw PageFetchError.tooLarge(maxBytes: maxBytes)
        }

        guard await FetchDestinationPolicy.allows(url, resolveHost: resolveHost) else {
            throw PageFetchError.blockedDestination
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(
            "text/html, application/xhtml+xml, text/plain, application/pdf",
            forHTTPHeaderField: "Accept"
        )

        let redirectGuard = RedirectGuard(resolveHost: resolveHost)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        } catch let error as URLError where error.code == .timedOut {
            throw PageFetchError.timeout
        } catch {
            throw PageFetchError.network(error.localizedDescription)
        }

        // A refused redirect surfaces as the 3xx response itself.
        guard !redirectGuard.didBlockRedirect else {
            throw PageFetchError.blockedDestination
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PageFetchError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw PageFetchError.httpStatus(httpResponse.statusCode)
        }

        let mimeType = (httpResponse.mimeType ?? "").lowercased()
        guard Self.acceptedMIMETypes.contains(mimeType) else {
            throw PageFetchError.unsupportedContentType(httpResponse.mimeType)
        }

        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))

        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count == maxBytes {
                    break
                }
            }
        } catch let error as URLError where error.code == .timedOut {
            throw PageFetchError.timeout
        } catch {
            throw PageFetchError.network(error.localizedDescription)
        }

        let bodyText: String
        if mimeType == "application/pdf" {
            // A truncated PDF cannot be parsed reliably, unlike text formats.
            // Hitting the byte cap means the tail was cut off regardless of
            // whether the server declared a Content-Length.
            let wasTruncated = httpResponse.expectedContentLength > Int64(maxBytes)
                || data.count == maxBytes
            guard !wasTruncated else {
                throw PageFetchError.tooLarge(maxBytes: maxBytes)
            }
            guard let document = PDFDocument(data: data) else {
                throw PageFetchError.invalidPDF
            }
            bodyText = (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
        } else {
            bodyText = String(decoding: data, as: UTF8.self)
        }

        return FetchedPage(
            finalURL: httpResponse.url ?? url,
            mimeType: mimeType,
            bodyText: bodyText
        )
    }
}

/// Re-applies ``FetchDestinationPolicy`` to every redirect hop, so a public
/// page can't bounce the fetcher onto a private-network service.
private nonisolated final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let resolveHost: FetchDestinationPolicy.HostResolver
    private let blocked = Mutex(false)

    init(resolveHost: @escaping FetchDestinationPolicy.HostResolver) {
        self.resolveHost = resolveHost
    }

    var didBlockRedirect: Bool {
        blocked.withLock { $0 }
    }

    // The completion-handler form, not the async one: Swift 6.4 crashes
    // emitting the Objective-C thunk for the async variant.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        Task {
            guard let url = request.url,
                  await FetchDestinationPolicy.allows(url, resolveHost: resolveHost) else {
                blocked.withLock { $0 = true }
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
