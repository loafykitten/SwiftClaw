import Foundation
import PDFKit

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

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(url: URL, maxBytes: Int) async throws -> FetchedPage {
        guard maxBytes > 0 else {
            throw PageFetchError.tooLarge(maxBytes: maxBytes)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(
            "text/html, application/xhtml+xml, text/plain, application/pdf",
            forHTTPHeaderField: "Accept"
        )

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw PageFetchError.timeout
        } catch {
            throw PageFetchError.network(error.localizedDescription)
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
