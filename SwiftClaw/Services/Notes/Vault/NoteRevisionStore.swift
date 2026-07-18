import CryptoKit
import Foundation

/// A single content snapshot captured before a mutation. Content-agnostic —
/// the store never parses or interprets `content`, so this type (and
/// `NoteRevisionStore` itself) is reusable outside Notes later (e.g.
/// email-draft history, per `docs/features/NOTES.md` cross-feature follow-up #6).
struct NoteRevision: Sendable, Equatable, Identifiable {
    /// Stable, filesystem-safe identifier (embeds the capture time, so
    /// listings sort chronologically by `id` alone).
    let id: String
    let key: String
    let content: String
    let createdAt: Date
}

/// Lightweight row used by revision-history listings. Full snapshot content
/// stays on disk until the user chooses a revision to restore.
struct NoteRevisionMetadata: Sendable, Equatable, Identifiable {
    let id: String
    let key: String
    let preview: String
    let createdAt: Date
}

nonisolated enum NoteRevisionPreview {
    static let maxCharacterCount = 240

    static func make(from content: String, hasMoreContent: Bool = false) -> String {
        var previewContent = content
        if let frontMatter = FrontMatterBlock(source: content) {
            previewContent = String(content[frontMatter.range.upperBound...])
        }
        let normalized = previewContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return hasMoreContent ? "…" : "Empty note" }
        let prefix = String(normalized.prefix(maxCharacterCount))
        return prefix.count == normalized.count && !hasMoreContent ? prefix : prefix + "…"
    }
}

/// Persists point-in-time content snapshots for arbitrary string-keyed
/// callers, entirely **outside** whatever store owns the live content (for
/// Notes: outside the vault, at `App Support/SwiftClaw/Notes/Revisions/
/// <vaultID>/`, per `VaultConfigurationStore.revisionsDirectory()`). An
/// **actor**: revision capture happens on the same mutation path as vault
/// writes and must never interleave two snapshots for the same key.
actor NoteRevisionStore {
    enum RevisionError: LocalizedError {
        case invalidContent(String)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidContent(let key):
                "Couldn't encode the revision content for \"\(key)\"."
            case .ioFailure(let message):
                message
            }
        }
    }

    static let maxRevisionsPerKey = 50
    static let maxRevisionAge: TimeInterval = 30 * 24 * 60 * 60
    /// Listing work stays bounded even for very large snapshots. Revision
    /// files are UTF-8 written by this store; `String(decoding:)` safely
    /// replaces only a scalar split at this read boundary.
    static let maxPreviewReadBytes = 32 * 1024

    private let directory: URL
    private let fileManager: FileManager
    private let clock: () -> Date
    private let idSuffixGenerator: () -> String
    private let idTimestampFormatter: DateFormatter

    /// `clock` and `idSuffixGenerator` are injectable so pruning
    /// (age-based and count-based) is deterministic under test.
    init(
        directory: URL,
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init,
        idSuffixGenerator: @escaping () -> String = { String(UUID().uuidString.prefix(8)) }
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.clock = clock
        self.idSuffixGenerator = idSuffixGenerator
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmssSSS"
        self.idTimestampFormatter = formatter
    }

    /// Captures `content` as a new revision under `key` (an arbitrary,
    /// caller-defined identifier — Notes uses the note's vault-relative
    /// path). Intended to be called immediately before every mutation to
    /// that key's live content, so a revision always exists for the
    /// pre-mutation state. Prunes that key's history afterward.
    @discardableResult
    func snapshot(key: String, content: String) throws -> NoteRevision {
        guard let data = content.data(using: .utf8) else {
            throw RevisionError.invalidContent(key)
        }
        let keyDirectory = directory.appendingPathComponent(Self.directoryName(forKey: key), isDirectory: true)
        let createdAt = clock()
        let id = "\(idTimestampFormatter.string(from: createdAt))-\(idSuffixGenerator())"
        let fileURL = keyDirectory.appendingPathComponent("\(id).revision")

        do {
            try AtomicFileWriter.write(data, to: fileURL, fileManager: fileManager)
        } catch {
            throw RevisionError.ioFailure("Couldn't save a revision for \"\(key)\": \(error.localizedDescription)")
        }

        try prune(keyDirectory: keyDirectory, now: createdAt)
        return NoteRevision(id: id, key: key, content: content, createdAt: createdAt)
    }

    /// All surviving revisions for `key`, newest first. Each file contributes
    /// only metadata and a bounded preview; full content is loaded by
    /// `revision(forKey:id:)` only when restore needs it.
    func revisions(forKey key: String) throws -> [NoteRevisionMetadata] {
        let keyDirectory = directory.appendingPathComponent(Self.directoryName(forKey: key), isDirectory: true)
        guard fileManager.fileExists(atPath: keyDirectory.path) else { return [] }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: keyDirectory, includingPropertiesForKeys: nil)
        } catch {
            throw RevisionError.ioFailure("Couldn't list revisions for \"\(key)\": \(error.localizedDescription)")
        }

        return entries.compactMap { url -> NoteRevisionMetadata? in
            guard let id = Self.revisionID(from: url), let createdAt = captureDate(fromID: id) else { return nil }
            guard let preview = try? Self.preview(from: url) else { return nil }
            return NoteRevisionMetadata(id: id, key: key, preview: preview, createdAt: createdAt)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Loads one full snapshot for restore. A missing or unreadable file is
    /// reported as `nil` so the repository preserves its existing
    /// `revisionNotFound` user-facing error path.
    func revision(forKey key: String, id: String) throws -> NoteRevision? {
        guard id == (id as NSString).lastPathComponent else { return nil }
        let keyDirectory = directory.appendingPathComponent(Self.directoryName(forKey: key), isDirectory: true)
        let url = keyDirectory.appendingPathComponent("\(id).revision")
        guard Self.revisionID(from: url) == id,
              fileManager.fileExists(atPath: url.path),
              let createdAt = captureDate(fromID: id)
        else { return nil }

        do {
            let data = try Data(contentsOf: url)
            guard let content = String(data: data, encoding: .utf8) else { return nil }
            return NoteRevision(id: id, key: key, content: content, createdAt: createdAt)
        } catch {
            throw RevisionError.ioFailure("Couldn't load revision \"\(id)\" for \"\(key)\": \(error.localizedDescription)")
        }
    }

    private static func preview(from url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxPreviewReadBytes + 1) ?? Data()
        let hasMoreContent = data.count > maxPreviewReadBytes
        let prefix = data.prefix(maxPreviewReadBytes)
        return NoteRevisionPreview.make(
            from: String(decoding: prefix, as: UTF8.self),
            hasMoreContent: hasMoreContent
        )
    }

    // MARK: - Pruning

    private func prune(keyDirectory: URL, now: Date) throws {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: keyDirectory, includingPropertiesForKeys: nil)
        } catch {
            throw RevisionError.ioFailure("Couldn't list revisions to prune: \(error.localizedDescription)")
        }

        let dated: [(url: URL, createdAt: Date)] = entries.compactMap { url in
            guard let id = Self.revisionID(from: url), let createdAt = captureDate(fromID: id) else { return nil }
            return (url, createdAt)
        }
        .sorted { $0.createdAt > $1.createdAt }

        let cutoff = now.addingTimeInterval(-Self.maxRevisionAge)
        var kept = 0
        for entry in dated {
            if entry.createdAt < cutoff {
                try? fileManager.removeItem(at: entry.url)
                continue
            }
            kept += 1
            if kept > Self.maxRevisionsPerKey {
                try? fileManager.removeItem(at: entry.url)
            }
        }
    }

    // MARK: - Identifiers

    private static func directoryName(forKey key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func revisionID(from url: URL) -> String? {
        guard url.pathExtension == "revision" else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    private func captureDate(fromID id: String) -> Date? {
        guard let timestampPart = id.split(separator: "-").first else { return nil }
        return idTimestampFormatter.date(from: String(timestampPart))
    }
}
