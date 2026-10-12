import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
enum ImageImportPipeline {
    static let preferredImageContentTypes: [UTType] = [
        .png,
        .jpeg,
        .tiff,
        .heic,
        .heif,
        .gif,
        .webP,
    ]

    static let supportedContentTypes: [UTType] = preferredImageContentTypes + [
        .image,
        .fileURL,
    ]

    static let openPanelContentTypes: [UTType] = preferredImageContentTypes + [.image]

    static func images(from transfers: [ImageImportTransfer]) async throws -> [PlatformImage] {
        try await images(fromSources: transfers.map(\.source))
    }

    static func images(fromFileURLs urls: [URL]) async throws -> [PlatformImage] {
        try await images(
            fromSources: urls.map {
                .fileURL(
                    $0,
                    contentTypeIdentifier: nil,
                    requiresSecurityScopedAccess: true
                )
            }
        )
    }

    #if os(macOS)
    static func imagesForPaste(
        from pasteboard: NSPasteboard = .general
    ) async throws -> [PlatformImage] {
        try await images(fromSources: pasteboardSources(from: pasteboard))
    }

    static func pasteboardSources(
        from pasteboard: NSPasteboard = .general
    ) -> [ImageImportSource] {
        var collectedSources: [ImageImportSource] = []

        for item in pasteboard.pasteboardItems ?? [] {
            collectedSources.append(contentsOf: sources(fromPasteboardItem: item))
        }

        if collectedSources.isEmpty, let image = NSImage(pasteboard: pasteboard), let data = image.tiffRepresentation {
            collectedSources.append(.data(data, contentTypeIdentifier: UTType.tiff.identifier))
        }

        return collectedSources
    }
    #endif

    static func images(fromSources sources: [ImageImportSource]) async throws -> [PlatformImage] {
        defer {
            removeTemporaryFiles(from: sources)
        }

        let images = try await decodeImages(fromSources: sources)
        guard !images.isEmpty else {
            throw ImageAttachmentError.noReadableImage
        }

        return images
    }

    static func images(fromProviders providers: [NSItemProvider]) async -> [PlatformImage] {
        let sources = await providerSources(from: providers)
        return await bestEffortImages(fromSources: sources)
    }

    private static func decodeImages(fromSources sources: [ImageImportSource]) async throws -> [PlatformImage] {
        var images: [PlatformImage] = []

        for source in sources {
            try Task.checkCancellation()

            guard let image = image(from: source) else {
                continue
            }

            images.append(image)
        }

        return images
    }

    private static func bestEffortImages(fromSources sources: [ImageImportSource]) async -> [PlatformImage] {
        defer {
            removeTemporaryFiles(from: sources)
        }

        var images: [PlatformImage] = []

        for source in sources {
            guard !Task.isCancelled, let image = image(from: source) else {
                continue
            }

            images.append(image)
        }

        return images
    }

    private static func image(from source: ImageImportSource) -> PlatformImage? {
        switch source.payload {
        case .data(let data, let contentTypeIdentifier):
            guard isSupportedImageContentType(contentTypeIdentifier) else {
                return nil
            }

            return PlatformImage(data: data)

        case .fileURL(let url, let contentTypeIdentifier, let requiresSecurityScopedAccess, _):
            guard url.isFileURL else {
                return nil
            }

            let didStartAccessing = requiresSecurityScopedAccess
                ? url.startAccessingSecurityScopedResource()
                : false
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let contentType = contentTypeIdentifier.flatMap(UTType.init)
                ?? contentType(forFileURL: url)
            guard contentType?.conforms(to: .image) ?? true else {
                return nil
            }

            guard let data = try? Data(contentsOf: url) else {
                return nil
            }

            return PlatformImage(data: data)
        }
    }

    #if os(macOS)
    private static func sources(fromPasteboardItem item: NSPasteboardItem) -> [ImageImportSource] {
        if let url = fileURL(from: item) {
            return [
                .fileURL(
                    url,
                    contentTypeIdentifier: nil,
                    requiresSecurityScopedAccess: true
                ),
            ]
        }

        // One item usually carries the same image as several representations
        // (PNG + TIFF, …): take the first one that decodes, in preference
        // order, so a single paste yields a single attachment.
        for contentType in pasteboardImageContentTypes {
            let pasteboardType = NSPasteboard.PasteboardType(contentType.identifier)
            guard let data = item.data(forType: pasteboardType),
                  NSImage(data: data) != nil else {
                continue
            }

            return [.data(data, contentTypeIdentifier: contentType.identifier)]
        }

        return []
    }

    private static var pasteboardImageContentTypes: [UTType] {
        preferredImageContentTypes + [.image]
    }

    private static func fileURL(from item: NSPasteboardItem) -> URL? {
        if let fileURLString = item.string(forType: .fileURL),
           let url = URL(string: fileURLString) {
            return url
        }

        if let urlString = item.string(forType: .URL),
           let url = URL(string: urlString),
           url.isFileURL {
            return url
        }

        return nil
    }
    #endif

    private static func removeTemporaryFiles(from sources: [ImageImportSource]) {
        for source in sources {
            source.removeTemporaryFiles()
        }
    }

    private static func providerSources(from providers: [NSItemProvider]) async -> [ImageImportSource] {
        var sources: [ImageImportSource] = []

        for provider in providers {
            guard !Task.isCancelled, let source = await source(from: provider) else {
                continue
            }

            sources.append(source)
        }

        return sources
    }

    private static func source(from provider: NSItemProvider) async -> ImageImportSource? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let fileURL = await fileURL(from: provider) {
            return .fileURL(
                fileURL,
                contentTypeIdentifier: nil,
                requiresSecurityScopedAccess: true
            )
        }

        if let contentType = preferredImageContentTypes.first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) ?? provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }),
           let data = await data(from: provider, contentType: contentType) {
            return .data(data, contentTypeIdentifier: contentType.identifier)
        }

        return nil
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { item, _ in
                continuation.resume(returning: item as? URL ?? (item as? NSURL).map { $0 as URL })
            }
        }
    }

    private static func data(from provider: NSItemProvider, contentType: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: contentType.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func contentType(forFileURL url: URL) -> UTType? {
        if let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return resourceType
        }

        return UTType(filenameExtension: url.pathExtension)
    }

    private static func isSupportedImageContentType(_ contentTypeIdentifier: String?) -> Bool {
        guard let contentTypeIdentifier,
              let contentType = UTType(contentTypeIdentifier) else {
            return true
        }

        return contentType.conforms(to: .image)
    }
}

private extension NSItemProvider {
    var registeredContentTypes: [UTType] {
        registeredTypeIdentifiers.compactMap(UTType.init)
    }
}
