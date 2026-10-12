import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import SwiftClaw

@MainActor
struct ImageAttachmentStoreTests {
    @Test func writesUUIDNamedDraftFiles() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }

        let records = try fixture.store.importImages(
            [Self.image(width: 120, height: 80)],
            existingAttachments: []
        )

        #expect(records.count == 1)
        #expect(records[0].fileURL.lastPathComponent == "\(records[0].id.uuidString).jpg")
        #expect(FileManager.default.fileExists(atPath: records[0].filePath))
        #expect(records[0].byteCount > 0)
    }

    @Test func finalizesDraftImagesIntoChatFolder() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let chatID = UUID()
        let draftRecords = try fixture.store.importImages(
            [Self.image(width: 120, height: 80)],
            existingAttachments: []
        )

        let finalized = try fixture.store.finalizeDraftAttachments(draftRecords, for: chatID)

        #expect(finalized.count == 1)
        #expect(finalized[0].filePath.contains(chatID.uuidString))
        #expect(FileManager.default.fileExists(atPath: finalized[0].filePath))
    }

    @Test func asynchronouslyFinalizesDraftImagesIntoChatFolder() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let chatID = UUID()
        let draftRecords = try fixture.store.importImages(
            [Self.image(width: 120, height: 80)],
            existingAttachments: []
        )

        let finalized = try await fixture.store.finalizeDraftAttachmentsAsync(draftRecords, for: chatID)

        #expect(finalized.count == 1)
        #expect(finalized[0].filePath.contains(chatID.uuidString))
        #expect(FileManager.default.fileExists(atPath: finalized[0].filePath))
    }

    @Test func deletesImagesForChat() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let chatID = UUID()
        let draftRecords = try fixture.store.importImages(
            [Self.image(width: 120, height: 80)],
            existingAttachments: []
        )
        let finalized = try fixture.store.finalizeDraftAttachments(draftRecords, for: chatID)

        fixture.store.deleteImages(for: chatID)

        #expect(!FileManager.default.fileExists(atPath: finalized[0].filePath))
    }

    @Test func enforcesImageCountLimit() throws {
        let fixture = try StoreFixture(limits: ImageAttachmentLimits(
            maxImageCount: 1,
            maxPixelLength: 4096,
            maxBytesPerImage: 10 * 1024 * 1024,
            maxBytesTotal: 100 * 1024 * 1024
        ))
        defer { fixture.cleanup() }

        #expect(throws: ImageAttachmentError.imageCountExceeded(1)) {
            try fixture.store.importImages(
                [
                    Self.image(width: 20, height: 20),
                    Self.image(width: 20, height: 20),
                ],
                existingAttachments: []
            )
        }
    }

    @Test func downscalesImagesOverPixelLimit() throws {
        let fixture = try StoreFixture(limits: ImageAttachmentLimits(
            maxImageCount: 10,
            maxPixelLength: 64,
            maxBytesPerImage: 10 * 1024 * 1024,
            maxBytesTotal: 100 * 1024 * 1024
        ))
        defer { fixture.cleanup() }

        let records = try fixture.store.importImages(
            [Self.image(width: 256, height: 128)],
            existingAttachments: []
        )

        #expect(max(records[0].pixelWidth, records[0].pixelHeight) == 64)
    }

    @Test func enforcesPerImageSizeLimit() throws {
        let fixture = try StoreFixture(limits: ImageAttachmentLimits(
            maxImageCount: 10,
            maxPixelLength: 4096,
            maxBytesPerImage: 1,
            maxBytesTotal: 100 * 1024 * 1024
        ))
        defer { fixture.cleanup() }

        #expect(throws: ImageAttachmentError.imageTooLarge(1)) {
            try fixture.store.importImages(
                [Self.image(width: 80, height: 80)],
                existingAttachments: []
            )
        }
    }

    @Test func enforcesTotalSizeLimit() throws {
        let fixture = try StoreFixture(limits: ImageAttachmentLimits(
            maxImageCount: 10,
            maxPixelLength: 4096,
            maxBytesPerImage: 10 * 1024 * 1024,
            maxBytesTotal: 1
        ))
        defer { fixture.cleanup() }

        #expect(throws: ImageAttachmentError.totalSizeExceeded(1)) {
            try fixture.store.importImages(
                [Self.image(width: 80, height: 80)],
                existingAttachments: []
            )
        }
    }

    @Test func missingImageFilesDoNotBreakInferenceMessageSetup() async throws {
        let missing = ImageAttachmentRecord(
            filePath: "/tmp/swiftclaw-missing-\(UUID().uuidString).jpg",
            byteCount: 10,
            pixelWidth: 10,
            pixelHeight: 10
        )

        _ = await InferenceMessage.user("hello", imageAttachments: [missing]).chatParam
    }

    @Test func importsDroppedImageData() async throws {
        let provider = NSItemProvider()
        let data = try #require(Self.image(width: 32, height: 24).tiffRepresentation)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.tiff.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }

        let images = await ImageDropImporter.images(from: [provider])

        #expect(images.count == 1)
    }

    @Test func importsDroppedImageFileURLs() async throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let url = fixture.rootDirectory.appendingPathComponent("drop.tiff")
        let data = try #require(Self.image(width: 32, height: 24).tiffRepresentation)
        try data.write(to: url)
        let provider = NSItemProvider(object: url as NSURL)

        let images = await ImageDropImporter.images(from: [provider])

        #expect(images.count == 1)
    }

    // MARK: - Container relocation

    @Test func reRootsAStoredPathFromAnOldContainerOntoTheCurrentRoot() {
        let root = URL(fileURLWithPath: "/new/Application Support/SwiftClaw/ImageAttachments", isDirectory: true)
        let stale = "/old/Containers/X/Data/Library/Application Support/SwiftClaw/ImageAttachments/ChatImages/C/I.jpg"

        let rerooted = ImageAttachmentRecord.rerootedURL(forStoredPath: stale, attachmentRoot: root)

        #expect(rerooted?.path == "/new/Application Support/SwiftClaw/ImageAttachments/ChatImages/C/I.jpg")
    }

    @Test func leavesPathsOutsideAnAttachmentRootAlone() {
        let root = URL(fileURLWithPath: "/new/SwiftClaw/ImageAttachments", isDirectory: true)

        #expect(ImageAttachmentRecord.rerootedURL(forStoredPath: "/tmp/image.jpg", attachmentRoot: root) == nil)
        #expect(ImageAttachmentRecord.rerootedURL(
            forStoredPath: "/new/SwiftClaw/ImageAttachments/ChatImages/C/I.jpg",
            attachmentRoot: root
        ) == nil)
        #expect(ImageAttachmentRecord.rerootedURL(
            forStoredPath: "/old/SwiftClaw/ImageAttachments/../../etc/passwd",
            attachmentRoot: root
        ) == nil)
    }

    @Test func fileURLFallsBackToTheCurrentRootWhenTheStoredPathIsGone() throws {
        let chatDirectory = ImageAttachmentStore.defaultRootDirectory
            .appendingPathComponent("ChatImages", isDirectory: true)
            .appendingPathComponent("SwiftClawTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chatDirectory) }
        let currentURL = chatDirectory.appendingPathComponent("image.jpg")
        try Data([0xFF]).write(to: currentURL)

        let staleRecord = ImageAttachmentRecord(
            filePath: "/OldContainer/SwiftClaw/ImageAttachments/ChatImages/"
                + "\(chatDirectory.lastPathComponent)/image.jpg",
            byteCount: 1,
            pixelWidth: 1,
            pixelHeight: 1
        )
        let missingRecord = ImageAttachmentRecord(
            filePath: "/OldContainer/SwiftClaw/ImageAttachments/ChatImages/missing/image.jpg",
            byteCount: 1,
            pixelWidth: 1,
            pixelHeight: 1
        )

        #expect(staleRecord.fileURL.standardizedFileURL == currentURL.standardizedFileURL)
        #expect(missingRecord.fileURL.path == missingRecord.filePath)
    }

    // MARK: - Pasteboard

    @Test func pasteboardItemWithSeveralRepresentationsYieldsOneSource() throws {
        let pasteboard = NSPasteboard(name: .init("SwiftClawTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let image = Self.image(width: 16, height: 16)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let sources = ImageImportPipeline.pasteboardSources(from: pasteboard)

        #expect(sources.count == 1)
        guard case .data(_, let contentType) = try #require(sources.first).payload else {
            Issue.record("Expected a data source")
            return
        }
        #expect(contentType == UTType.png.identifier)
    }

    @Test func pasteboardSkipsAnUndecodableRepresentationForTheNextOne() throws {
        let pasteboard = NSPasteboard(name: .init("SwiftClawTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let tiff = try #require(Self.image(width: 16, height: 16).tiffRepresentation)
        let item = NSPasteboardItem()
        item.setData(Data("not a png".utf8), forType: .png)
        item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let sources = ImageImportPipeline.pasteboardSources(from: pasteboard)

        #expect(sources.count == 1)
        guard case .data(_, let contentType) = try #require(sources.first).payload else {
            Issue.record("Expected a data source")
            return
        }
        #expect(contentType == UTType.tiff.identifier)
    }

    private static func image(width: Int, height: Int) -> NSImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let cgImage = context.makeImage()!
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}

@MainActor
private struct StoreFixture {
    let rootDirectory: URL
    let store: ImageAttachmentStore

    init(limits: ImageAttachmentLimits = ImageAttachmentLimits()) throws {
        rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftClawTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        store = ImageAttachmentStore(rootDirectory: rootDirectory, limits: limits)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
