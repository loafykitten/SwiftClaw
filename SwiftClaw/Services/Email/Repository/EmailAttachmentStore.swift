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
            // Parts share the message's directory, so two `attachment.pdf`
            // parts (or names that sanitize identically) each need their own
            // file name or the later write replaces the earlier one.
            var usedNames: Set<String> = []
            let attachments = message.attachmentDescriptors.map { descriptor in
                var filePath = ""
                if let data = descriptor.data, !data.isEmpty {
                    let storageName = Self.uniqueName(
                        for: sanitizedFilename(descriptor.filename),
                        avoiding: &usedNames
                    )
                    filePath = (try? save(
                        data: data,
                        filename: storageName,
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

    /// Resolves an attachment's `filename` inside the email's directory.
    /// Prefer `absoluteURL(forRelativePath:)`: duplicate part names are stored
    /// under suffixed names, so only the stored path identifies the file.
    func absoluteURL(forEmailID emailID: UUID, filename: String) -> URL {
        emailDirectory(for: emailID).appendingPathComponent(sanitizedFilename(filename))
    }

    /// Resolves the relative `filePath` stored on `EmailAttachment` back to
    /// its absolute disk URL. `nil` for an empty path or one that would
    /// escape the attachment root.
    func absoluteURL(forRelativePath relativePath: String) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        let root = rootDirectory.standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return url
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

    /// `name`, or `name 2.ext`, `name 3.ext`, … — the first variant not yet in
    /// `used` (compared case-insensitively, as on default APFS volumes).
    private static func uniqueName(for name: String, avoiding used: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var counter = 2
        while used.contains(candidate.lowercased()) {
            let numbered = "\(base) \(counter)"
            candidate = ext.isEmpty ? numbered : "\(numbered).\(ext)"
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
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
