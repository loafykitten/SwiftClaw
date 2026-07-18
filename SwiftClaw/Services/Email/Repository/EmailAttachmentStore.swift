import Foundation

nonisolated struct PreparedFetchedMessage: Sendable {
    let message: FetchedMessage
    let emailID: UUID
    let attachments: [PreparedEmailAttachment]
}

nonisolated struct PreparedEmailAttachment: Sendable {
    let filename: String
    let filePath: String
    let mimeType: String
    let sizeBytes: Int
}

/// Persists email attachments on disk under
/// `~/Library/Application Support/SwiftClaw/EmailAttachments/<emailID>/<filename>`.
/// Mirrors `ImageAttachmentStore` (`Features/ImageAttachments/ImageAttachmentStore.swift:55-56,275-284`).
/// The immutable root plus FileManager's thread-safe operations allow account
/// sync tasks to prepare separate UUID directories concurrently.
nonisolated final class EmailAttachmentStore: @unchecked Sendable {
    static let shared = EmailAttachmentStore()

    private let rootDirectory: URL
    private let fileManager: FileManager

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
        self.fileManager = fileManager
    }

    /// Persists attachment data and returns the relative path to store on the
    /// `EmailAttachment` model. The path is resolved by `absoluteURL(forEmailID:filename:)`.
    @discardableResult
    func save(
        data: Data,
        filename: String,
        forEmailID emailID: UUID
    ) throws -> String {
        let directory = emailDirectory(for: emailID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeFilename = sanitizedFilename(filename)
        let url = directory.appendingPathComponent(safeFilename)
        try data.write(to: url, options: [.atomic])
        return relativePath(emailID: emailID, filename: safeFilename)
    }

    /// Performs attachment I/O before the caller enters its MainActor
    /// SwiftData transaction. Failed individual writes keep their metadata
    /// with an empty path, matching the viewer's existing unavailable state.
    func prepare(_ messages: [FetchedMessage]) -> [PreparedFetchedMessage] {
        messages.map { message in
            let emailID = UUID()
            let attachments = message.attachmentDescriptors.map { descriptor in
                var filePath = ""
                if let data = descriptor.data, !data.isEmpty {
                    filePath = (try? save(
                        data: data,
                        filename: descriptor.filename,
                        forEmailID: emailID
                    )) ?? ""
                }
                return PreparedEmailAttachment(
                    filename: descriptor.filename,
                    filePath: filePath,
                    mimeType: descriptor.mimeType,
                    sizeBytes: descriptor.sizeBytes
                )
            }
            return PreparedFetchedMessage(
                message: message,
                emailID: emailID,
                attachments: attachments
            )
        }
    }

    func deletePreparedMessages(_ messages: [PreparedFetchedMessage]) {
        for message in messages {
            deleteAttachments(forEmailID: message.emailID)
        }
    }

    /// Resolves a relative `filePath` stored on `EmailAttachment` back to its
    /// absolute disk URL.
    func absoluteURL(forEmailID emailID: UUID, filename: String) -> URL {
        emailDirectory(for: emailID).appendingPathComponent(sanitizedFilename(filename))
    }

    func deleteAttachments(forEmailID emailID: UUID) {
        try? fileManager.removeItem(at: emailDirectory(for: emailID))
    }

    private func emailDirectory(for emailID: UUID) -> URL {
        rootDirectory.appendingPathComponent(emailID.uuidString, isDirectory: true)
    }

    private func relativePath(emailID: UUID, filename: String) -> String {
        "\(emailID.uuidString)/\(filename)"
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "attachment" }
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return trimmed.components(separatedBy: invalid).joined(separator: "_")
    }

    private static func defaultRootDirectory(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return applicationSupport
            .appendingPathComponent("SwiftClaw", isDirectory: true)
            .appendingPathComponent("EmailAttachments", isDirectory: true)
    }
}
