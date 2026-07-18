import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageAttachmentLimits: Sendable {
    var maxImageCount = 10
    var maxPixelLength = 4096
    var maxBytesPerImage = 10 * 1024 * 1024
    var maxBytesTotal = 100 * 1024 * 1024

    nonisolated init(
        maxImageCount: Int = 10,
        maxPixelLength: Int = 4096,
        maxBytesPerImage: Int = 10 * 1024 * 1024,
        maxBytesTotal: Int = 100 * 1024 * 1024
    ) {
        self.maxImageCount = maxImageCount
        self.maxPixelLength = maxPixelLength
        self.maxBytesPerImage = maxBytesPerImage
        self.maxBytesTotal = maxBytesTotal
    }
}

enum ImageAttachmentError: LocalizedError, Equatable {
    case noReadableImage
    case imageCountExceeded(Int)
    case imageTooLarge(Int)
    case totalSizeExceeded(Int)
    case missingFile
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noReadableImage:
            "Couldn't read that image."
        case .imageCountExceeded(let limit):
            "You can attach up to \(limit) images."
        case .imageTooLarge(let limit):
            "Each image must be \(Self.byteLimitLabel(limit)) or smaller."
        case .totalSizeExceeded(let limit):
            "Images can use up to \(Self.byteLimitLabel(limit)) total."
        case .missingFile:
            "Couldn't find one of the attached images."
        case .writeFailed:
            "Couldn't save that image."
        }
    }

    private static func byteLimitLabel(_ bytes: Int) -> String {
        let megabytes = Double(bytes) / 1024.0 / 1024.0
        return "\(Int(megabytes.rounded())) MB"
    }
}

@MainActor
final class ImageAttachmentStore {
    static let shared = ImageAttachmentStore()

    let limits: ImageAttachmentLimits

    private let rootDirectory: URL
    private let fileManager: FileManager

    init(
        rootDirectory: URL? = nil,
        limits: ImageAttachmentLimits = ImageAttachmentLimits(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.limits = limits
        self.fileManager = fileManager
    }

    func importImages(
        _ images: [PlatformImage],
        existingAttachments: [ImageAttachmentRecord]
    ) throws -> [ImageAttachmentRecord] {
        guard !images.isEmpty else {
            return []
        }

        guard existingAttachments.count + images.count <= limits.maxImageCount else {
            throw ImageAttachmentError.imageCountExceeded(limits.maxImageCount)
        }

        try createDirectoryIfNeeded(draftDirectory)

        var createdRecords: [ImageAttachmentRecord] = []
        do {
            for image in images {
                let normalized = try normalizedJPEGData(from: image)
                let runningTotal = existingAttachments.map(\.byteCount).reduce(0, +)
                    + createdRecords.map(\.byteCount).reduce(0, +)
                    + normalized.data.count

                guard runningTotal <= limits.maxBytesTotal else {
                    throw ImageAttachmentError.totalSizeExceeded(limits.maxBytesTotal)
                }

                let id = UUID()
                let url = draftDirectory.appendingPathComponent("\(id.uuidString).jpg")
                do {
                    try normalized.data.write(to: url, options: [.atomic])
                } catch {
                    throw ImageAttachmentError.writeFailed
                }

                createdRecords.append(ImageAttachmentRecord(
                    id: id,
                    filePath: url.path,
                    byteCount: normalized.data.count,
                    pixelWidth: normalized.width,
                    pixelHeight: normalized.height
                ))
            }

            return createdRecords
        } catch {
            deleteAttachments(createdRecords)
            throw error
        }
    }

    func finalizeDraftAttachments(
        _ attachments: [ImageAttachmentRecord],
        for chatID: UUID
    ) throws -> [ImageAttachmentRecord] {
        guard !attachments.isEmpty else {
            return []
        }

        let directory = chatDirectory(for: chatID)
        try createDirectoryIfNeeded(directory)

        var finalized: [ImageAttachmentRecord] = []
        do {
            for attachment in attachments {
                let sourceURL = attachment.fileURL
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    throw ImageAttachmentError.missingFile
                }

                let destinationURL = directory.appendingPathComponent(attachment.fileName)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                finalized.append(attachment.relocated(
                    to: destinationURL,
                    byteCount: fileSize(at: destinationURL) ?? attachment.byteCount
                ))
            }

            return finalized
        } catch {
            deleteAttachments(finalized)
            throw error
        }
    }

    func finalizeDraftAttachmentsAsync(
        _ attachments: [ImageAttachmentRecord],
        for chatID: UUID
    ) async throws -> [ImageAttachmentRecord] {
        guard !attachments.isEmpty else {
            return []
        }

        let directory = chatDirectory(for: chatID)
        return try await Task.detached(priority: .userInitiated) {
            try Self.finalizeAttachments(attachments, in: directory)
        }.value
    }

    func deleteDraftAttachments(_ attachments: [ImageAttachmentRecord]) {
        for attachment in attachments where isDraftAttachment(attachment) {
            try? fileManager.removeItem(at: attachment.fileURL)
        }
    }

    func deleteAttachments(_ attachments: [ImageAttachmentRecord]) {
        for attachment in attachments {
            try? fileManager.removeItem(at: attachment.fileURL)
        }
    }

    func deleteImages(for chatID: UUID) {
        try? fileManager.removeItem(at: chatDirectory(for: chatID))
    }

    func chatDirectory(for chatID: UUID) -> URL {
        chatImagesDirectory.appendingPathComponent(chatID.uuidString, isDirectory: true)
    }

    func imageData(for attachment: ImageAttachmentRecord) -> Data? {
        try? Data(contentsOf: attachment.fileURL)
    }

    private var draftDirectory: URL {
        rootDirectory.appendingPathComponent("DraftImages", isDirectory: true)
    }

    private var chatImagesDirectory: URL {
        rootDirectory.appendingPathComponent("ChatImages", isDirectory: true)
    }

    private func normalizedJPEGData(from image: PlatformImage) throws -> (data: Data, width: Int, height: Int) {
        guard let sourceImage = image.attachmentCGImage else {
            throw ImageAttachmentError.noReadableImage
        }

        let sourceWidth = sourceImage.width
        let sourceHeight = sourceImage.height
        let longestEdge = max(sourceWidth, sourceHeight)
        let scale = longestEdge > limits.maxPixelLength
            ? Double(limits.maxPixelLength) / Double(longestEdge)
            : 1.0
        let targetWidth = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let targetHeight = max(1, Int((Double(sourceHeight) * scale).rounded()))

        guard let renderedImage = render(
            sourceImage,
            width: targetWidth,
            height: targetHeight
        ) else {
            throw ImageAttachmentError.noReadableImage
        }

        for quality in stride(from: 0.9, through: 0.45, by: -0.05) {
            guard let data = jpegData(from: renderedImage, quality: quality) else {
                continue
            }

            if data.count <= limits.maxBytesPerImage {
                return (data, targetWidth, targetHeight)
            }
        }

        throw ImageAttachmentError.imageTooLarge(limits.maxBytesPerImage)
    }

    private func render(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )

        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func isDraftAttachment(_ attachment: ImageAttachmentRecord) -> Bool {
        attachment.fileURL.path.hasPrefix(draftDirectory.path)
    }

    private func fileSize(at url: URL) -> Int? {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }

        return size.intValue
    }

    private nonisolated static func finalizeAttachments(
        _ attachments: [ImageAttachmentRecord],
        in directory: URL
    ) throws -> [ImageAttachmentRecord] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var finalized: [ImageAttachmentRecord] = []
        do {
            for attachment in attachments {
                let sourceURL = attachment.fileURL
                guard fileManager.fileExists(atPath: sourceURL.path) else {
                    throw ImageAttachmentError.missingFile
                }

                let destinationURL = directory.appendingPathComponent(attachment.fileName)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                let attributes = try? fileManager.attributesOfItem(atPath: destinationURL.path)
                let byteCount = (attributes?[.size] as? NSNumber)?.intValue
                finalized.append(attachment.relocated(
                    to: destinationURL,
                    byteCount: byteCount ?? attachment.byteCount
                ))
            }
            return finalized
        } catch {
            for attachment in finalized {
                try? fileManager.removeItem(at: attachment.fileURL)
            }
            throw error
        }
    }

    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return applicationSupport
            .appendingPathComponent("SwiftClaw", isDirectory: true)
            .appendingPathComponent("ImageAttachments", isDirectory: true)
    }
}
