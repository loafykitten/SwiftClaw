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
            let transferredFile = try Self.importedFileURL(for: received.file, isOriginalFile: received.isOriginalFile)
            return ImageImportTransfer(
                source: .fileURL(
                    transferredFile.url,
                    contentTypeIdentifier: nil,
                    requiresSecurityScopedAccess: received.isOriginalFile,
                    temporaryDirectoryURL: transferredFile.temporaryDirectoryURL
                )
            )
        }

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

        ProxyRepresentation(importing: { (url: URL) in
            guard url.isFileURL else {
                throw ImageImportTransferError.unsupportedRemoteURL
            }

            return ImageImportTransfer(
                source: .fileURL(
                    url,
                    contentTypeIdentifier: nil,
                    requiresSecurityScopedAccess: true
                )
            )
        })
    }

    private nonisolated init(data: Data, contentType: UTType) {
        source = .data(data, contentTypeIdentifier: contentType.identifier)
    }

    private nonisolated static func importedFileURL(
        for url: URL,
        isOriginalFile: Bool
    ) throws -> (url: URL, temporaryDirectoryURL: URL?) {
        guard !isOriginalFile else {
            return (url, nil)
        }

        return try copyTransferredFile(url)
    }

    private nonisolated static func copyTransferredFile(_ url: URL) throws -> (url: URL, temporaryDirectoryURL: URL) {
        let fileManager = FileManager.default
        let directoryURL = try temporaryImportDirectory(fileManager: fileManager)
        let destinationURL = directoryURL.appendingPathComponent(
            url.lastPathComponent.isEmpty ? UUID().uuidString : url.lastPathComponent,
            isDirectory: false
        )

        do {
            try fileManager.copyItem(at: url, to: destinationURL)
            return (destinationURL, directoryURL)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    private nonisolated static func temporaryImportDirectory(fileManager: FileManager) throws -> URL {
        let baseDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory

        let directoryURL = baseDirectory
            .appendingPathComponent("SwiftClaw", isDirectory: true)
            .appendingPathComponent("ImageImportTransfers", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}

private enum ImageImportTransferError: Error {
    case unsupportedRemoteURL
}

struct ImageImportSource: Sendable {
    enum Payload: Sendable {
        case data(Data, contentTypeIdentifier: String?)
        case fileURL(
            URL,
            contentTypeIdentifier: String?,
            requiresSecurityScopedAccess: Bool,
            temporaryDirectoryURL: URL?
        )
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
        requiresSecurityScopedAccess: Bool,
        temporaryDirectoryURL: URL? = nil
    ) -> ImageImportSource {
        ImageImportSource(
            payload: .fileURL(
                url,
                contentTypeIdentifier: contentTypeIdentifier,
                requiresSecurityScopedAccess: requiresSecurityScopedAccess,
                temporaryDirectoryURL: temporaryDirectoryURL
            )
        )
    }

    nonisolated var temporaryDirectoryURL: URL? {
        guard case .fileURL(_, _, _, let temporaryDirectoryURL) = payload else {
            return nil
        }

        return temporaryDirectoryURL
    }

    nonisolated func removeTemporaryFiles(fileManager: FileManager = .default) {
        guard let temporaryDirectoryURL else {
            return
        }

        try? fileManager.removeItem(at: temporaryDirectoryURL)
    }
}
