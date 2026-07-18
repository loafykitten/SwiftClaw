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

    private func makeFetcher(
        statusCode: Int,
        mimeType: String,
        body: Data
    ) -> PageFetcher {
        StubPageURLProtocol.response.update {
            $0 = .init(statusCode: statusCode, mimeType: mimeType, body: body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubPageURLProtocol.self]
        return PageFetcher(session: URLSession(configuration: configuration))
    }
}

nonisolated private final class StubPageURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse {
        let statusCode: Int
        let mimeType: String
        let body: Data
    }

    static let response = LockedValue<StubResponse?>(nil)

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
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
