import AppKit
import Foundation
import UniformTypeIdentifiers

enum ImageDropImporter {
    static let supportedContentTypes: [UTType] = [
        .fileURL,
        .image,
    ]

    @MainActor
    static func images(from providers: [NSItemProvider]) async -> [NSImage] {
        var images: [NSImage] = []

        for provider in providers {
            guard let source = await imageSource(from: provider),
                  let image = source.image else {
                continue
            }

            images.append(image)
        }

        return images
    }

    @MainActor
    private static func imageSource(from provider: NSItemProvider) async -> ImageDropSource? {
        let typeIdentifiers = provider.registeredTypeIdentifiers

        if typeIdentifiers.contains(where: { identifier in
            UTType(identifier)?.conforms(to: .fileURL) == true
        }) {
            return await loadFileImageSource(from: provider)
        }

        if let imageTypeIdentifier = typeIdentifiers.first(where: { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }) {
            return await loadDataImageSource(from: provider, typeIdentifier: imageTypeIdentifier)
        }

        return nil
    }

    @MainActor
    private static func loadFileImageSource(
        from provider: NSItemProvider
    ) async -> ImageDropSource? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { item, _ in
                guard let url = item as? NSURL else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: .fileURL(url as URL))
            }
        }
    }

    @MainActor
    private static func loadDataImageSource(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async -> ImageDropSource? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data.map(ImageDropSource.data))
            }
        }
    }
}

private enum ImageDropSource {
    case data(Data)
    case fileURL(URL)

    @MainActor
    var image: NSImage? {
        switch self {
        case .data(let data):
            NSImage(data: data)
        case .fileURL(let url):
            NSImage(contentsOf: url)
        }
    }
}
