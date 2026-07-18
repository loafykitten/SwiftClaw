import Foundation

nonisolated struct ImageAttachmentRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var filePath: String
    var byteCount: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var createdAt: Date

    nonisolated init(
        id: UUID = UUID(),
        filePath: String,
        byteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.filePath = filePath
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.createdAt = createdAt
    }

    nonisolated var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    nonisolated var fileName: String {
        "\(id.uuidString).jpg"
    }

    nonisolated var pixelSizeLabel: String {
        "\(pixelWidth)x\(pixelHeight)"
    }

    nonisolated func relocated(to url: URL, byteCount: Int? = nil) -> ImageAttachmentRecord {
        ImageAttachmentRecord(
            id: id,
            filePath: url.path,
            byteCount: byteCount ?? self.byteCount,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            createdAt: createdAt
        )
    }
}
