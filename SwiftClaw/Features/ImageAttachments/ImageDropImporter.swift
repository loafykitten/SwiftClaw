#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
enum ImageDropImporter {
    static let supportedContentTypes = ImageImportPipeline.supportedContentTypes

    static func images(from providers: [NSItemProvider]) async -> [NSImage] {
        await ImageImportPipeline.images(fromProviders: providers)
    }
}
#endif
