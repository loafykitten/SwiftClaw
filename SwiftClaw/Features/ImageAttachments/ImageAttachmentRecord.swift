import Foundation

struct ImageAttachmentRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var filePath: String
    var byteCount: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var createdAt: Date

    init(
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

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
    }

    var fileName: String {
        "\(id.uuidString).jpg"
    }

    var pixelSizeLabel: String {
        "\(pixelWidth)x\(pixelHeight)"
    }

    func relocated(to url: URL, byteCount: Int? = nil) -> ImageAttachmentRecord {
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

