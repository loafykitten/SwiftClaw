import CoreGraphics
import Foundation
import Testing
@testable import SwiftClaw

@Suite("Page fetcher", .serialized)
struct PageFetcherTests {
    @Test func acceptsSupportedTextContentTypes() async throws {
        let url = try #require(URL(string: "https://example.com/start"))
        for mimeType in ["text/html", "application/xhtml+xml", "text/plain"] {
            let fetcher = makeFetcher(statusCode: 200, mimeType: mimeType, body: Data("hello".utf8))
            let page = try await fetcher.fetch(url: url, maxBytes: 100)

            #expect(page.mimeType == mimeType)
            #expect(page.bodyText == "hello")
            #expect(page.finalURL.absoluteString == "https://example.com/start")
        }
    }

    @Test func acceptsPDFContent() async throws {
        let url = try #require(URL(string: "https://example.com/document.pdf"))
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let fetcher = makeFetcher(
            statusCode: 200,
            mimeType: "application/pdf",
            body: data as Data
        )

        let page = try await fetcher.fetch(url: url, maxBytes: 10_000)

        #expect(page.mimeType == "application/pdf")
    }

    @Test func rejectsUnsupportedContentType() async throws {
        let fetcher = makeFetcher(statusCode: 200, mimeType: "image/png", body: Data([0, 1]))
        let url = try #require(URL(string: "https://example.com/image"))

        await #expect(throws: PageFetchError.unsupportedContentType("image/png")) {
            try await fetcher.fetch(url: url, maxBytes: 100)
        }
    }

    @Test func reportsHTTPFailures() async throws {
        let fetcher = makeFetcher(statusCode: 403, mimeType: "text/html", body: Data())
        let url = try #require(URL(string: "https://example.com/blocked"))

        await #expect(throws: PageFetchError.httpStatus(403)) {
            try await fetcher.fetch(url: url, maxBytes: 100)
        }
    }

    @Test func truncatesTextAtByteCap() async throws {
        let url = try #require(URL(string: "https://example.com/large"))
        let fetcher = makeFetcher(
            statusCode: 200,
            mimeType: "text/plain",
            body: Data("0123456789".utf8)
        )

        let page = try await fetcher.fetch(url: url, maxBytes: 5)

        #expect(page.bodyText == "01234")
        #expect(Data(page.bodyText.utf8).count == 5)
    }

    @Test func rejectsPrivateLiteralAndNonHTTPDestinationsWithoutRequesting() async throws {
        let fetcher = makeFetcher(statusCode: 200, mimeType: "text/plain", body: Data("secret".utf8))
        let blocked = [
            "http://127.0.0.1/admin",
            "http://[::1]:8080/",
            "http://10.0.0.5/",
            "http://169.254.169.254/latest/meta-data",
            "http://[::ffff:192.168.1.1]/",
            "file:///etc/hosts",
            "ftp://example.com/file.txt",
        ]

        for string in blocked {
            let url = try #require(URL(string: string))
            await #expect(throws: PageFetchError.blockedDestination) {
                try await fetcher.fetch(url: url, maxBytes: 100)
            }
        }
        #expect(StubPageURLProtocol.requestedURLs.value.isEmpty)
    }

    @Test func rejectsHostsThatResolveToPrivateOrNoAddresses() async throws {
        let fetcher = makeFetcher(
            statusCode: 200,
            mimeType: "text/plain",
            body: Data("secret".utf8),
            resolveHost: { host in
                switch host {
                case "intranet.example": [[192, 168, 0, 10]]
                case "mixed.example": [[93, 184, 216, 34], [127, 0, 0, 1]]
                default: []
                }
            }
        )

        for host in ["intranet.example", "mixed.example", "unresolvable.example"] {
            let url = try #require(URL(string: "https://\(host)/"))
            await #expect(throws: PageFetchError.blockedDestination) {
                try await fetcher.fetch(url: url, maxBytes: 100)
            }
        }
        #expect(StubPageURLProtocol.requestedURLs.value.isEmpty)
    }

    @Test func refusesRedirectIntoPrivateNetwork() async throws {
        let fetcher = makeFetcher(
            statusCode: 200,
            mimeType: "text/plain",
            body: Data("internal service".utf8),
            redirects: ["https://example.com/start": "http://127.0.0.1:8080/internal"]
        )
        let url = try #require(URL(string: "https://example.com/start"))

        await #expect(throws: PageFetchError.blockedDestination) {
            try await fetcher.fetch(url: url, maxBytes: 100)
        }
        #expect(StubPageURLProtocol.requestedURLs.value == ["https://example.com/start"])
    }

    @Test func followsRedirectToPublicDestination() async throws {
        let fetcher = makeFetcher(
            statusCode: 200,
            mimeType: "text/plain",
            body: Data("moved".utf8),
            redirects: ["https://example.com/start": "https://example.org/final"]
        )
        let url = try #require(URL(string: "https://example.com/start"))

        let page = try await fetcher.fetch(url: url, maxBytes: 100)

        #expect(page.bodyText == "moved")
        #expect(page.finalURL.absoluteString == "https://example.org/final")
        #expect(StubPageURLProtocol.requestedURLs.value == [
            "https://example.com/start",
            "https://example.org/final",
        ])
    }

    /// A stalled `getaddrinfo` must not hold Stop or a run deadline hostage:
    /// cancellation fails the lookup closed right away, and the lookup's late
    /// answer is dropped without resuming anything twice.
    @Test func stalledHostLookupReturnsPromptlyWhenCancelled() async throws {
        let lookupStarted = DispatchSemaphore(value: 0)
        let unstall = DispatchSemaphore(value: 0)
        let lookupFinished = DispatchSemaphore(value: 0)
        let lookup: @Sendable (String) -> [[UInt8]] = { _ in
            lookupStarted.signal()
            unstall.wait()
            defer { lookupFinished.signal() }
            return [[93, 184, 216, 34]]
        }

        let resolution = Task { await FetchDestinationPolicy.resolve("stalled.example", blockingLookup: lookup) }
        await waitOffCooperativePool(lookupStarted)
        resolution.cancel()

        #expect(await resolution.value.isEmpty)

        // The late answer lands on a waiter that already resumed.
        unstall.signal()
        await waitOffCooperativePool(lookupFinished)
    }

    /// The research deadline cancels its fetch child and then waits for it,
    /// so a fetch stuck in DNS must end on cancellation, not on DNS.
    @Test func fetchCancelledDuringAStalledLookupThrowsCancellation() async throws {
        let lookupStarted = DispatchSemaphore(value: 0)
        let unstall = DispatchSemaphore(value: 0)
        defer { unstall.signal() }
        let fetcher = makeFetcher(
            statusCode: 200,
            mimeType: "text/plain",
            body: Data("never fetched".utf8),
            resolveHost: { host in
                await FetchDestinationPolicy.resolve(host) { _ in
                    lookupStarted.signal()
                    unstall.wait()
                    return [[93, 184, 216, 34]]
                }
            }
        )
        let url = try #require(URL(string: "https://stalled.example/"))

        let fetch = Task { try await fetcher.fetch(url: url, maxBytes: 100) }
        await waitOffCooperativePool(lookupStarted)
        fetch.cancel()

        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(StubPageURLProtocol.requestedURLs.value.isEmpty)
    }

    @Test func classifiesAddresses() throws {
        let publicHosts = ["93.184.216.34", "8.8.8.8", "2606:4700::1111", "::ffff:8.8.8.8"]
        let privateHosts = [
            "0.0.0.0", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.0.1",
            "172.31.255.255", "192.168.1.1", "224.0.0.1", "255.255.255.255", "::", "::1",
            "fc00::1", "fd12:3456::1", "fe80::1", "ff02::1", "::ffff:10.0.0.1",
            "64:ff9b::7f00:1", "2002:c0a8:0101::1",
        ]

        for host in publicHosts {
            let address = try #require(FetchDestinationPolicy.numericAddress(host))
            #expect(FetchDestinationPolicy.isPublicAddress(address), "\(host)")
        }
        for host in privateHosts {
            let address = try #require(FetchDestinationPolicy.numericAddress(host))
            #expect(!FetchDestinationPolicy.isPublicAddress(address), "\(host)")
        }
    }

    /// Blocks a GCD thread, not a cooperative-pool one, on `semaphore`.
    private func waitOffCooperativePool(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }

    /// Stub DNS: every name resolves to a public address unless overridden,
    /// so tests never depend on the network.
    private func makeFetcher(
        statusCode: Int,
        mimeType: String,
        body: Data,
        redirects: [String: String] = [:],
        resolveHost: @escaping FetchDestinationPolicy.HostResolver = { _ in [[93, 184, 216, 34]] }
    ) -> PageFetcher {
        StubPageURLProtocol.response.update {
            $0 = .init(statusCode: statusCode, mimeType: mimeType, body: body)
        }
        StubPageURLProtocol.redirects.update { $0 = redirects }
        StubPageURLProtocol.requestedURLs.update { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubPageURLProtocol.self]
        return PageFetcher(
            session: URLSession(configuration: configuration),
            resolveHost: resolveHost
        )
    }
}

nonisolated private final class StubPageURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let statusCode: Int
        let mimeType: String
        let body: Data
    }

    static let response = LockedValue<StubResponse?>(nil)
    /// Source URL → `Location` for a 302 hop.
    static let redirects = LockedValue<[String: String]>([:])
    static let requestedURLs = LockedValue<[String]>([])

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let url = request.url {
            Self.requestedURLs.update { $0.append(url.absoluteString) }
        }

        if let url = request.url,
           let location = Self.redirects.value[url.absoluteString],
           let target = URL(string: location),
           let redirect = HTTPURLResponse(
               url: url,
               statusCode: 302,
               httpVersion: nil,
               headerFields: ["Location": location]
           ) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
            // When the delegate refuses the hop, the 302 itself completes the task.
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        guard let stub = Self.response.value,
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: nil,
                  headerFields: ["Content-Type": stub.mimeType]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
