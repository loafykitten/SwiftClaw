import CryptoKit
import Foundation

/// A byte-exact snapshot of one vault note at the moment it was read/written.
struct NoteFileSnapshot: Sendable, Equatable {
    let relativePath: String
    let content: String
    let sha256: String
    let modifiedAt: Date
}

/// The outcome of `NotesVault.write`. `.conflict` means the caller's content
/// was never applied to `relativePath` — it landed in a sibling "(conflict
/// …)" copy instead, and the original file on disk is untouched.
enum NoteWriteOutcome: Sendable, Equatable {
    case wrote(NoteFileSnapshot)
    case conflict(conflictSnapshot: NoteFileSnapshot)
}

/// The only type that touches vault files. An **actor** so every
/// enumerate/read/write/rename/delete on a given vault instance is
/// serialized — no torn reads racing a write from a repository call and a
/// reconciler rescan at once.
///
/// Every relative path is validated against `root` before touching disk
/// (rejects `..`/absolute escapes and, once a candidate exists, symlink
/// escapes) and every operation runs inside a `scopeAccessor` bracket so an
/// external (security-scoped) vault never gets touched outside an active
/// access grant.
actor NotesVault {
    enum VaultError: LocalizedError, Equatable {
        case invalidRelativePath(String)
        case invalidUTF8(String)
        case fileNotFound(String)
        case destinationExists(String)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidRelativePath(let path):
                "\"\(path)\" isn't a valid note path."
            case .invalidUTF8(let path):
                "\"\(path)\" isn't valid UTF-8 text and can't be opened as a note."
            case .fileNotFound(let path):
                "\"\(path)\" doesn't exist in the vault."
            case .destinationExists(let path):
                "\"\(path)\" already exists."
            case .ioFailure(let message):
                message
            }
        }

        static func == (lhs: VaultError, rhs: VaultError) -> Bool {
            lhs.errorDescription == rhs.errorDescription
        }
    }

    /// Resolves (and holds open) security-scoped access for the vault root,
    /// for the duration of one operation. Returns `nil` for an app-managed
    /// vault, which needs no security scope.
    typealias ScopeAccessor = @Sendable () async throws -> ScopedURL?

    private let root: URL
    private let standardizedRootPath: String
    private let resolvedRoot: URL
    private let resolvedRootPrefix: String
    private let fileManager: FileManager
    private let scopeAccessor: ScopeAccessor
    private let conflictTimestampFormatter: DateFormatter

    init(
        root: URL,
        fileManager: FileManager = .default,
        scopeAccessor: @escaping ScopeAccessor = { nil }
    ) {
        self.root = root
        let standardizedPath = root.standardizedFileURL.path
        self.standardizedRootPath = standardizedPath.hasSuffix("/") ? standardizedPath : standardizedPath + "/"
        self.resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedPath = self.resolvedRoot.path
        self.resolvedRootPrefix = resolvedPath.hasSuffix("/") ? resolvedPath : resolvedPath + "/"
        self.fileManager = fileManager
        self.scopeAccessor = scopeAccessor
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        self.conflictTimestampFormatter = formatter
    }

    /// All Markdown note relative paths in the vault, ignore rules applied,
    /// sorted for deterministic output.
    func enumerate() async throws -> [String] {
        try await withScope {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            var results: [String] = []
            try walk(directory: root, relativePrefix: "", into: &results)
            return results.sorted()
        }
    }

    func read(relativePath: String) async throws -> NoteFileSnapshot {
        try await withScope {
            let url = try resolveExistingURL(for: relativePath)
            return try snapshot(at: url, relativePath: relativePath)
        }
    }

    /// Whether a file already exists at `relativePath`, without reading it.
    /// Lets callers (e.g. `NotesRepository.create`) probe for filename
    /// collisions before attempting a write, so a foreseeable collision never
    /// has to burn a `write`'s create-only conflict-copy fallback just to
    /// discover the name was taken.
    func exists(relativePath: String) async throws -> Bool {
        try await withScope {
            let url = try resolveURL(for: relativePath)
            guard !isSymbolicLink(at: url) else {
                throw VaultError.invalidRelativePath(relativePath)
            }
            return fileManager.fileExists(atPath: url.path)
        }
    }

    /// Writes `content` to `relativePath`. `expectedHash` guards against
    /// clobbering a change this caller hasn't seen: it is re-checked against
    /// the file's *current on-disk hash* immediately before writing (never
    /// against a hash captured earlier by the caller). `nil` means
    /// create-only — the write is expected to be the first content at that
    /// path. Either way, a mismatch never overwrites: the attempted content
    /// is saved as a `Name (conflict <timestamp>).md` sibling and the
    /// existing file is left exactly as it was.
    @discardableResult
    func write(relativePath: String, content: String, expectedHash: String?) async throws -> NoteWriteOutcome {
        try await withScope {
            let url = try resolveMutationURL(for: relativePath)
            guard let data = content.data(using: .utf8) else {
                throw VaultError.invalidUTF8(relativePath)
            }

            let exists = fileManager.fileExists(atPath: url.path)
            let currentHash = exists ? try Self.sha256Hex(contentsOf: url) : nil
            let matchesCurrentState: Bool
            if let expectedHash {
                matchesCurrentState = currentHash == expectedHash
            } else {
                matchesCurrentState = !exists
            }

            guard matchesCurrentState else {
                let conflictURL = try makeConflictURL(for: url)
                try AtomicFileWriter.write(data, to: conflictURL, fileManager: fileManager)
                let conflictRelativePath = try computeRelativePath(for: conflictURL)
                return .conflict(conflictSnapshot: try snapshot(at: conflictURL, relativePath: conflictRelativePath))
            }

            try AtomicFileWriter.write(data, to: url, fileManager: fileManager)
            return .wrote(try snapshot(at: url, relativePath: relativePath))
        }
    }

    /// Moves a note. Never clobbers an existing file at `newRelativePath` —
    /// callers must resolve naming conflicts themselves before calling this.
    @discardableResult
    func rename(from relativePath: String, to newRelativePath: String) async throws -> NoteFileSnapshot {
        try await withScope {
            let sourceURL = try resolveExistingURL(for: relativePath)
            let destinationURL = try resolveMutationURL(for: newRelativePath)
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                throw VaultError.destinationExists(newRelativePath)
            }
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                throw VaultError.ioFailure("Couldn't rename \"\(relativePath)\": \(error.localizedDescription)")
            }
            return try snapshot(at: destinationURL, relativePath: newRelativePath)
        }
    }

    /// Moves a note to the Trash rather than deleting it outright.
    func delete(relativePath: String) async throws {
        try await withScope {
            let url = try resolveExistingURL(for: relativePath)
            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
            } catch {
                throw VaultError.ioFailure("Couldn't delete \"\(relativePath)\": \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Security scope bracketing

    private func withScope<T: Sendable>(_ body: () throws -> T) async throws -> T {
        let scope = try await scopeAccessor()
        return try withExtendedLifetime(scope) {
            try body()
        }
    }

    // MARK: - Path safety

    /// Validates `relativePath` and resolves it to a URL under `root`,
    /// without requiring the file to exist. Rejects absolute paths, `.`/`..`
    /// components, and any candidate that (after standardization) lands
    /// outside `root` — path traversal and absolute-path escapes are caught
    /// before any filesystem call is made.
    private func resolveURL(for relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw VaultError.invalidRelativePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw VaultError.invalidRelativePath(relativePath)
        }

        let candidate = root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        guard candidate.path.hasPrefix(standardizedRootPath) else {
            throw VaultError.invalidRelativePath(relativePath)
        }
        return candidate
    }

    /// `resolveURL(for:)` plus an existence check and symlink checks. A
    /// directory symlink planted inside the vault must not grant access to
    /// whatever it targets, and a symbolic-link file is never a vault note
    /// (even if its target happens to be inside the vault).
    private func resolveExistingURL(for relativePath: String) throws -> URL {
        let url = try resolveURL(for: relativePath)
        guard fileManager.fileExists(atPath: url.path) else {
            throw VaultError.fileNotFound(relativePath)
        }
        guard !isSymbolicLink(at: url) else {
            throw VaultError.invalidRelativePath(relativePath)
        }
        let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard resolvedParent.path == resolvedRoot.path || resolvedParent.path.hasPrefix(resolvedRootPrefix) else {
            throw VaultError.invalidRelativePath(relativePath)
        }
        return url
    }

    /// Resolves a path that is about to be created or moved to. The lexical
    /// check in `resolveURL(for:)` is not sufficient for a new file: a parent
    /// directory can be a symlink to a location outside the vault even though
    /// the final file does not exist yet. Validate the nearest existing parent
    /// before allowing directory creation or a write/move.
    private func resolveMutationURL(for relativePath: String) throws -> URL {
        let url = try resolveURL(for: relativePath)
        try validateExistingParent(of: url, relativePath: relativePath)
        guard !isSymbolicLink(at: url) else {
            throw VaultError.invalidRelativePath(relativePath)
        }
        return url
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private func validateExistingParent(of url: URL, relativePath: String) throws {
        var parent = url.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: parent.path) {
            let nextParent = parent.deletingLastPathComponent()
            guard nextParent.path != parent.path else {
                throw VaultError.invalidRelativePath(relativePath)
            }
            parent = nextParent
        }

        let resolvedParent = parent.resolvingSymlinksInPath()
        guard resolvedParent.path == resolvedRoot.path || resolvedParent.path.hasPrefix(resolvedRootPrefix) else {
            throw VaultError.invalidRelativePath(relativePath)
        }
    }

    private func computeRelativePath(for url: URL) throws -> String {
        let standardized = url.standardizedFileURL.path
        guard standardized.hasPrefix(standardizedRootPath) else {
            throw VaultError.invalidRelativePath(url.path)
        }
        return String(standardized.dropFirst(standardizedRootPath.count))
    }

    // MARK: - Enumeration

    private func walk(directory: URL, relativePrefix: String, into results: inout [String]) throws {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw VaultError.ioFailure("Couldn't list \"\(relativePrefix)\": \(error.localizedDescription)")
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let relativePath = relativePrefix.isEmpty ? name : relativePrefix + "/" + name

            // Symlinks are never vault entries. This also avoids following a
            // Markdown-file symlink out of the vault during enumeration.
            if values?.isSymbolicLink == true { continue }

            if values?.isDirectory == true {
                if VaultIgnoreRules.isIgnoredDirectory(name: name) { continue }
                try walk(directory: entry, relativePrefix: relativePath, into: &results)
            } else {
                if VaultIgnoreRules.isIgnoredFile(name: name) { continue }
                results.append(relativePath)
            }
        }
    }

    // MARK: - Hashing & snapshots

    private func snapshot(at url: URL, relativePath: String) throws -> NoteFileSnapshot {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VaultError.ioFailure("Couldn't read \"\(relativePath)\": \(error.localizedDescription)")
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw VaultError.invalidUTF8(relativePath)
        }
        let mtime = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        return NoteFileSnapshot(
            relativePath: relativePath,
            content: content,
            sha256: Self.sha256Hex(data),
            modifiedAt: mtime
        )
    }

    private func makeConflictURL(for url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let timestamp = conflictTimestampFormatter.string(from: Date())

        func candidate(suffix: Int) -> URL {
            let disambiguator = suffix > 1 ? " \(suffix)" : ""
            let name = "\(baseName) (conflict \(timestamp)\(disambiguator)).\(ext)"
            return directory.appendingPathComponent(name)
        }

        var suffix = 1
        var result = candidate(suffix: suffix)
        while fileManager.fileExists(atPath: result.path) {
            suffix += 1
            result = candidate(suffix: suffix)
        }
        return result
    }

    private static func sha256Hex(contentsOf url: URL) throws -> String {
        sha256Hex(try Data(contentsOf: url))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
