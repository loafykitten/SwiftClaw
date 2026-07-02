#if os(macOS)
import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct ImageImportTransfer: Transferable, Sendable {
    let source: ImageImportSource

    nonisolated init(source: ImageImportSource) {
        self.source = source
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image, shouldAttemptToOpenInPlace: true) { received in
            ImageImportTransfer(
                source: .fileURL(
                    received.file,
                    contentTypeIdentifier: nil,
                    requiresSecurityScopedAccess: received.isOriginalFile
                )
            )
        }

        ProxyRepresentation(importing: { (url: URL) in
            ImageImportTransfer(
                source: .fileURL(
                    url,
                    contentTypeIdentifier: nil,
                    requiresSecurityScopedAccess: true
                )
            )
        })

        DataRepresentation(importedContentType: .png) { data in
            ImageImportTransfer(data: data, contentType: .png)
        }

        DataRepresentation(importedContentType: .jpeg) { data in
            ImageImportTransfer(data: data, contentType: .jpeg)
        }

        DataRepresentation(importedContentType: .tiff) { data in
            ImageImportTransfer(data: data, contentType: .tiff)
        }

        DataRepresentation(importedContentType: .heic) { data in
            ImageImportTransfer(data: data, contentType: .heic)
        }

        DataRepresentation(importedContentType: .heif) { data in
            ImageImportTransfer(data: data, contentType: .heif)
        }

        DataRepresentation(importedContentType: .gif) { data in
            ImageImportTransfer(data: data, contentType: .gif)
        }

        DataRepresentation(importedContentType: .webP) { data in
            ImageImportTransfer(data: data, contentType: .webP)
        }

        DataRepresentation(importedContentType: .image) { data in
            ImageImportTransfer(data: data, contentType: .image)
        }
    }

    private nonisolated init(data: Data, contentType: UTType) {
        source = .data(data, contentTypeIdentifier: contentType.identifier)
    }
}

struct ImageImportSource: Sendable {
    enum Payload: Sendable {
        case data(Data, contentTypeIdentifier: String?)
        case fileURL(URL, contentTypeIdentifier: String?, requiresSecurityScopedAccess: Bool)
    }

    let payload: Payload

    nonisolated init(payload: Payload) {
        self.payload = payload
    }

    nonisolated static func data(_ data: Data, contentTypeIdentifier: String?) -> ImageImportSource {
        ImageImportSource(payload: .data(data, contentTypeIdentifier: contentTypeIdentifier))
    }

    nonisolated static func fileURL(
        _ url: URL,
        contentTypeIdentifier: String?,
        requiresSecurityScopedAccess: Bool
    ) -> ImageImportSource {
        ImageImportSource(
            payload: .fileURL(
                url,
                contentTypeIdentifier: contentTypeIdentifier,
                requiresSecurityScopedAccess: requiresSecurityScopedAccess
            )
        )
    }
}
#endif
