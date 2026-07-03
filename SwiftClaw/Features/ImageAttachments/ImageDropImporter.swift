import UniformTypeIdentifiers

@MainActor
enum ImageDropImporter {
    static let supportedContentTypes = ImageImportPipeline.supportedContentTypes

    static func images(from providers: [NSItemProvider]) async -> [PlatformImage] {
        await ImageImportPipeline.images(fromProviders: providers)
    }
}
