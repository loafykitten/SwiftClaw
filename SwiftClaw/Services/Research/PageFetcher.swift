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
            "The page address points to a local or private network, or could not be resolved or verified."
        case .network(let message):
            "The page request failed: \(message)"
        }
    }
}

/// Fetches bounded HTML, plain-text, and PDF research sources.
nonisolated struct PageFetcher: Sendable {
    /// Maps one transaction of a finished task's metrics to the connection it
    /// made. A seam so tests can stand in for the addresses a stub protocol
    /// can't report; production reads the metrics as-is.
    typealias ConnectionReader = @Sendable (URLSessionTaskTransactionMetrics) -> FetchDestinationPolicy.Connection

    static let requestTimeout: TimeInterval = 15

    /// How long to wait for URLSession to deliver a finished task's metrics.
    /// They normally land within milliseconds of completion or cancellation;
    /// if they never do, the fetch fails closed.
    static let metricsTimeout: Duration = .seconds(5)

    private static let acceptedMIMETypes: Set<String> = [
        "text/html",
        "application/xhtml+xml",
        "text/plain",
        "application/pdf",
    ]

    /// Isolated from `URLSession.shared`: no cookies, credentials, or cache
    /// are shared with the rest of the app or carried between sources. With
    /// no URL cache every transaction is a network load, and with no proxy it
    /// connects directly, so its metrics name the address the target resolved
    /// to (a proxy would resolve it out of sight of the destination policy).
    static let isolatedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession
    private let resolveHost: FetchDestinationPolicy.HostResolver
    private let readConnection: ConnectionReader

    init(
        session: URLSession = PageFetcher.isolatedSession,
        resolveHost: @escaping FetchDestinationPolicy.HostResolver = FetchDestinationPolicy.systemResolver,
        readConnection: @escaping ConnectionReader = { FetchDestinationPolicy.Connection($0) }
    ) {
        self.session = session
        self.resolveHost = resolveHost
        self.readConnection = readConnection
    }

    func fetch(url: URL, maxBytes: Int) async throws -> FetchedPage {
        guard maxBytes > 0 else {
            throw PageFetchError.tooLarge(maxBytes: maxBytes)
        }

        guard await FetchDestinationPolicy.allows(url, resolveHost: resolveHost) else {
            // A cancelled lookup fails closed; report it as the cancellation.
            try Task.checkCancellation()
            throw PageFetchError.blockedDestination
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(
            "text/html, application/xhtml+xml, text/plain, application/pdf",
            forHTTPHeaderField: "Accept"
        )

        let destinationGuard = DestinationGuard(resolveHost: resolveHost, readConnection: readConnection)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: destinationGuard)
        } catch let error as URLError where error.code == .timedOut {
            throw PageFetchError.timeout
        } catch {
            throw PageFetchError.network(error.localizedDescription)
        }

        var body = bytes.makeAsyncIterator()
        let received = await receive(&body, response: response, maxBytes: maxBytes)

        // The pre-flight check resolved the host itself; URLSession resolved
        // it again to connect, and DNS can answer differently the second time.
        // So nothing the server sent — body, status, or content type — reaches
        // the caller until the task metrics confirm every hop connected to a
        // public address. Metrics arrive only once the task completes: cancel
        // a transfer cut off early (a no-op once it completed), then read the
        // sequence to its end — an AsyncBytes task stays suspended until it's
        // read, so a cancelled but unread one would never complete.
        bytes.task.cancel()
        while (try? await body.next()) != nil {}
        guard let connections = await destinationGuard.connections(timeout: Self.metricsTimeout) else {
            try Task.checkCancellation()
            throw PageFetchError.blockedDestination
        }
        // A refused redirect surfaces as the 3xx response itself.
        guard !destinationGuard.didBlockRedirect,
              FetchDestinationPolicy.allowsConnections(connections) else {
            throw PageFetchError.blockedDestination
        }

        let (httpResponse, mimeType, data) = try received.get()
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

    /// Validates the response and reads at most `maxBytes` of its body. The
    /// outcome is held, not thrown, until the connections are verified.
    private func receive(
        _ body: inout URLSession.AsyncBytes.AsyncIterator,
        response: URLResponse,
        maxBytes: Int
    ) async -> Result<(HTTPURLResponse, String, Data), PageFetchError> {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(.invalidResponse)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            return .failure(.httpStatus(httpResponse.statusCode))
        }

        let mimeType = (httpResponse.mimeType ?? "").lowercased()
        guard Self.acceptedMIMETypes.contains(mimeType) else {
            return .failure(.unsupportedContentType(httpResponse.mimeType))
        }

        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))

        do {
            while let byte = try await body.next() {
                data.append(byte)
                if data.count == maxBytes {
                    break
                }
            }
        } catch let error as URLError where error.code == .timedOut {
            return .failure(.timeout)
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        return .success((httpResponse, mimeType, data))
    }
}

/// Re-applies ``FetchDestinationPolicy`` to every redirect hop, so a public
/// page can't bounce the fetcher onto a private-network service, and captures
/// the task's metrics so the fetch can check where each hop really connected.
private nonisolated final class DestinationGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private typealias Waiter = CheckedContinuation<[FetchDestinationPolicy.Connection]?, Never>

    private enum WaitOutcome {
        case ready([FetchDestinationPolicy.Connection]?)
        case waiting
    }

    private struct State {
        var didBlockRedirect = false
        /// Set once, when URLSession delivers the finished task's metrics.
        var connections: [FetchDestinationPolicy.Connection]?
        var waiter: Waiter?
        /// The waiter timed out or was cancelled; later metrics are ignored.
        var stoppedWaiting = false
    }

    private let resolveHost: FetchDestinationPolicy.HostResolver
    private let readConnection: PageFetcher.ConnectionReader
    private let state = Mutex(State())

    init(
        resolveHost: @escaping FetchDestinationPolicy.HostResolver,
        readConnection: @escaping PageFetcher.ConnectionReader
    ) {
        self.resolveHost = resolveHost
        self.readConnection = readConnection
    }

    var didBlockRedirect: Bool {
        state.withLock { $0.didBlockRedirect }
    }

    /// The connections of every transaction (one per redirect hop), once the
    /// task's metrics arrive. `nil` — fail closed — if they don't arrive
    /// within `timeout` or the calling task is cancelled first.
    func connections(timeout: Duration) async -> [FetchDestinationPolicy.Connection]? {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.stopWaiting()
        }
        defer { timer.cancel() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let outcome: WaitOutcome = state.withLock { state in
                    if let connections = state.connections { return .ready(connections) }
                    if state.stoppedWaiting { return .ready(nil) }
                    state.waiter = continuation
                    return .waiting
                }
                if case .ready(let connections) = outcome {
                    continuation.resume(returning: connections)
                }
            }
        } onCancel: {
            stopWaiting()
        }
    }

    private func stopWaiting() {
        let waiter: Waiter? = state.withLock { state in
            state.stoppedWaiting = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let connections = metrics.transactionMetrics.map(readConnection)
        let waiter: Waiter? = state.withLock { state in
            guard state.connections == nil else { return nil }
            state.connections = connections
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: connections)
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
                state.withLock { $0.didBlockRedirect = true }
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }
}
