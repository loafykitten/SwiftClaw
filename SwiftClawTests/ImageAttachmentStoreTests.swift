import AppKit
import Foundation
import Testing
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

    @Test func missingImageFilesDoNotBreakInferenceMessageSetup() throws {
        let missing = ImageAttachmentRecord(
            filePath: "/tmp/swiftclaw-missing-\(UUID().uuidString).jpg",
            byteCount: 10,
            pixelWidth: 10,
            pixelHeight: 10
        )

        _ = InferenceMessage.user("hello", imageAttachments: [missing]).chatParam
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
