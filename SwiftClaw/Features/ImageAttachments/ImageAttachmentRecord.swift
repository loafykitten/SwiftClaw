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

    /// `filePath` is stored absolute, so it goes stale when the app container
    /// moves (iOS restore, container relocation) even though the file now
    /// sits at the same spot under the current root. A missing stored path is
    /// re-rooted onto the current attachment root when the file exists there.
    nonisolated var fileURL: URL {
        let storedURL = URL(fileURLWithPath: filePath)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: filePath),
              let rerootedURL = Self.rerootedURL(
                forStoredPath: filePath,
                attachmentRoot: ImageAttachmentStore.defaultRootDirectory
              ),
              fileManager.fileExists(atPath: rerootedURL.path) else {
            return storedURL
        }
        return rerootedURL
    }

    /// Maps a stored path from an older container onto `attachmentRoot` by
    /// the path below the root's `<App>/<Attachments>/` suffix. Nil when the
    /// path isn't under such a root, or already points at `attachmentRoot`.
    nonisolated static func rerootedURL(forStoredPath path: String, attachmentRoot: URL) -> URL? {
        let rootSuffix = "/\(attachmentRoot.deletingLastPathComponent().lastPathComponent)/\(attachmentRoot.lastPathComponent)/"
        guard let range = path.range(of: rootSuffix, options: .backwards) else { return nil }

        let relativePath = String(path[range.upperBound...])
        guard !relativePath.isEmpty,
              !relativePath.split(separator: "/").contains("..") else {
            return nil
        }

        let rerootedURL = attachmentRoot.appendingPathComponent(relativePath)
        return rerootedURL.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path
            ? nil
            : rerootedURL
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
