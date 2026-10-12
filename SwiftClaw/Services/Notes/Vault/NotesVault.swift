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

/// The outcome of `NotesVault.createExclusive`. Unlike `NoteWriteOutcome`,
/// `.collision` writes absolutely nothing — no sibling copy, no overwrite —
/// because an exact-path create-only caller (`NotesRepository
/// .createExactPath`) wants the path taken to mean "propose again", not
/// "silently land somewhere else."
enum NoteCreateOutcome: Sendable, Equatable {
    case created(NoteFileSnapshot)
    case collision
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
        /// A hash-guarded operation found the file's content changed since
        /// the caller read it; nothing was moved or written.
        case contentChanged(String)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .contentChanged(let path):
                "\"\(path)\" changed since it was read."
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

    /// Reads the raw bytes at `relativePath`, with no UTF-8 decoding — for
    /// binary assets referenced by a note (e.g. an embedded image), which
    /// `read(relativePath:)` can't return since it requires valid UTF-8 text.
    /// Uses the same path-safety resolution as every other vault access, so
    /// this is never a route around `resolveExistingURL`'s traversal/symlink
    /// checks.
    func readData(relativePath: String) async throws -> Data {
        try await withScope {
            let url = try resolveExistingURL(for: relativePath)
            do {
                return try Data(contentsOf: url)
            } catch {
                throw VaultError.ioFailure(relativePath)
            }
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
    /// clobbering a change this caller hasn't seen. The current on-disk hash
    /// is checked *inside* an `NSFileCoordinator` replacement access, and
    /// the atomic publish happens before that access ends. That serializes
    /// the compare-and-replace with cooperating document editors on macOS and
    /// iOS; the hash is never validated in one access and published in a
    /// later, uncoordinated filesystem operation. `nil` means create-only —
    /// the write is expected to be the first content at that path. Either
    /// way, a mismatch never overwrites: the attempted content is saved as a
    /// `Name (conflict <timestamp>).md` sibling and the existing file is left
    /// exactly as it was.
    @discardableResult
    func write(relativePath: String, content: String, expectedHash: String?) async throws -> NoteWriteOutcome {
        try await withScope {
            let url = try resolveMutationURL(for: relativePath)
            guard let data = content.data(using: .utf8) else {
                throw VaultError.invalidUTF8(relativePath)
            }

            return try coordinateReplacement(at: url) { coordinatedURL in
                let exists = fileManager.fileExists(atPath: coordinatedURL.path)
                let currentHash = exists ? try Self.sha256Hex(contentsOf: coordinatedURL) : nil
                let matchesCurrentState: Bool
                if let expectedHash {
                    matchesCurrentState = currentHash == expectedHash
                } else {
                    matchesCurrentState = !exists
                }

                guard matchesCurrentState else {
                    // Coordinating the original note doesn't protect its
                    // sibling, so the copy is published create-only: a
                    // same-name file that appears after the unused-name
                    // check is never replaced.
                    return .conflict(
                        conflictSnapshot: try publishConflictCopy(data, besideCoordinated: coordinatedURL, logicalURL: url)
                    )
                }

                // Keep the hash comparison and this atomic replacement in the
                // same coordinated accessor. A document editor coordinating a
                // save cannot land an edit between them.
                try AtomicFileWriter.write(data, to: coordinatedURL, fileManager: fileManager)
                return .wrote(try snapshot(at: coordinatedURL, relativePath: relativePath))
            }
        }
    }

    /// Creates a uniquely named sibling conflict copy containing `content`
    /// while leaving the live note at `relativePath` byte-for-byte untouched.
    /// This is deliberately separate from `write`: revision restore must
    /// never manufacture a hash mismatch or risk replacing the current note.
    /// The destination is published create-only, so an external process that
    /// claims a same-second name simply makes this operation try the next
    /// deterministic suffix.
    func createConflictCopy(relativeTo relativePath: String, content: String) async throws -> NoteFileSnapshot {
        try await withScope {
            let logicalURL = try resolveExistingURL(for: relativePath)
            guard let data = content.data(using: .utf8) else {
                throw VaultError.invalidUTF8(relativePath)
            }

            return try coordinateReplacement(at: logicalURL) { coordinatedURL in
                do {
                    return try publishConflictCopy(data, besideCoordinated: coordinatedURL, logicalURL: logicalURL)
                } catch {
                    throw VaultError.ioFailure(
                        "Couldn't restore a revision for \"\(relativePath)\": \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Publishes `data` as a new `Name (conflict <timestamp>).md` sibling,
    /// create-only: an external process that claims the chosen name between
    /// `makeConflictURLs`'s unused-name check and publication makes this try
    /// the next deterministic suffix rather than overwrite that file.
    private func publishConflictCopy(
        _ data: Data,
        besideCoordinated coordinatedURL: URL,
        logicalURL: URL
    ) throws -> NoteFileSnapshot {
        while true {
            let conflictURLs = makeConflictURLs(for: coordinatedURL, matching: logicalURL)
            do {
                try AtomicFileWriter.createExclusive(
                    data,
                    at: conflictURLs.coordinatedURL,
                    fileManager: fileManager
                )
            } catch AtomicFileWriter.WriteError.alreadyExists {
                continue
            }
            let conflictRelativePath = try computeRelativePath(for: conflictURLs.logicalURL)
            return try snapshot(
                at: conflictURLs.coordinatedURL,
                relativePath: conflictRelativePath
            )
        }
    }

    /// Creates a note at `relativePath` only if nothing exists there yet,
    /// atomically — no sibling "(conflict …)" copy and no overwrite, ever,
    /// unlike `write(expectedHash: nil)`. Backed by `AtomicFileWriter
    /// .createExclusive`'s POSIX `O_EXCL` create, so the existence check and
    /// the write are a single kernel-atomic operation: no other process can
    /// race a separate read-then-write sequence into creating the same path
    /// first. Same path/symlink-escape validation as every other mutation
    /// (`resolveMutationURL`).
    @discardableResult
    func createExclusive(relativePath: String, content: String) async throws -> NoteCreateOutcome {
        try await withScope {
            let url = try resolveMutationURL(for: relativePath)
            guard let data = content.data(using: .utf8) else {
                throw VaultError.invalidUTF8(relativePath)
            }

            do {
                try AtomicFileWriter.createExclusive(data, at: url, fileManager: fileManager)
            } catch AtomicFileWriter.WriteError.alreadyExists {
                return .collision
            } catch {
                throw VaultError.ioFailure("Couldn't create \"\(relativePath)\": \(error.localizedDescription)")
            }
            return .created(try snapshot(at: url, relativePath: relativePath))
        }
    }

    /// Moves a note. Never clobbers an existing file at `newRelativePath` —
    /// callers must resolve naming conflicts themselves before calling this.
    /// A non-nil `expectedHash` makes the move conditional: the source's
    /// current hash is checked inside the same coordinated move access, so
    /// a cooperating editor's save can't land between the check and the
    /// move; a mismatch throws `.contentChanged` and moves nothing.
    @discardableResult
    func rename(
        from relativePath: String,
        to newRelativePath: String,
        expectedHash: String? = nil
    ) async throws -> NoteFileSnapshot {
        try await withScope {
            let sourceURL = try resolveExistingURL(for: relativePath)
            let destinationURL = try resolveMutationURL(for: newRelativePath)
            return try coordinateMove(from: sourceURL, to: destinationURL) { coordinatedSource, coordinatedDestination in
                if let expectedHash {
                    guard try Self.sha256Hex(contentsOf: coordinatedSource) == expectedHash else {
                        throw VaultError.contentChanged(relativePath)
                    }
                }
                guard !fileManager.fileExists(atPath: coordinatedDestination.path) else {
                    throw VaultError.destinationExists(newRelativePath)
                }
                try fileManager.createDirectory(
                    at: coordinatedDestination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try fileManager.moveItem(at: coordinatedSource, to: coordinatedDestination)
                } catch {
                    throw VaultError.ioFailure("Couldn't rename \"\(relativePath)\": \(error.localizedDescription)")
                }
                return try snapshot(at: coordinatedDestination, relativePath: newRelativePath)
            }
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

    /// Runs `accessor` under the platform document-coordination protocol used
    /// by macOS and iOS editors. The accessor URL is the only URL touched for
    /// the guarded target: file providers are allowed to substitute it while
    /// they coordinate a replacement.
    private func coordinateReplacement<T: Sendable>(
        at url: URL,
        accessor: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            result = Result { try accessor(coordinatedURL) }
        }

        if let coordinationError {
            throw VaultError.ioFailure("Couldn't coordinate a replacement for \"\(url.lastPathComponent)\": \(coordinationError.localizedDescription)")
        }
        guard let result else {
            throw VaultError.ioFailure("Couldn't coordinate a replacement for \"\(url.lastPathComponent)\".")
        }
        return try result.get()
    }

    /// The move counterpart of `coordinateReplacement`: coordinates the
    /// source for moving and the destination for replacing in one access,
    /// and tells presenters about a successful move.
    private func coordinateMove<T: Sendable>(
        from sourceURL: URL,
        to destinationURL: URL,
        accessor: (URL, URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?

        coordinator.coordinate(
            writingItemAt: sourceURL,
            options: .forMoving,
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedSource, coordinatedDestination in
            coordinator.item(at: coordinatedSource, willMoveTo: coordinatedDestination)
            result = Result { try accessor(coordinatedSource, coordinatedDestination) }
            if case .success = result {
                coordinator.item(at: coordinatedSource, didMoveTo: coordinatedDestination)
            }
        }

        if let coordinationError {
            throw VaultError.ioFailure("Couldn't coordinate a move for \"\(sourceURL.lastPathComponent)\": \(coordinationError.localizedDescription)")
        }
        guard let result else {
            throw VaultError.ioFailure("Couldn't coordinate a move for \"\(sourceURL.lastPathComponent)\".")
        }
        return try result.get()
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

        // Built by concatenating onto `standardizedRootPath` directly rather than
        // re-running `.standardizedFileURL` on the joined path: Foundation's
        // /private<->/tmp (and /var, /etc) symlink shortcut is only applied
        // consistently to the root by itself — re-standardizing the full
        // appended path can silently produce a different lexical form (e.g.
        // reintroducing the "/private" prefix `standardizedRootPath` already
        // had stripped), which then fails the prefix check below for a
        // perfectly valid new path. Components are already validated above to
        // exclude "", ".", and "..", so plain concatenation can't escape root.
        let candidate = URL(fileURLWithPath: standardizedRootPath + components.joined(separator: "/"))
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
        // `url` here is always already built off `standardizedRootPath` (via
        // `resolveURL`/`resolveMutationURL` or a plain `appendingPathComponent`
        // on such a URL in `makeConflictURL`), so re-running
        // `.standardizedFileURL` would risk the same /private<->/tmp lexical
        // drift that `resolveURL` avoids by concatenating directly.
        let path = url.path
        guard path.hasPrefix(standardizedRootPath) else {
            throw VaultError.invalidRelativePath(url.path)
        }
        return String(path.dropFirst(standardizedRootPath.count))
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

    /// Builds the conflict-copy's physical URL from the coordinator accessor,
    /// but its logical URL/name from the already-validated vault URL. A file
    /// provider may substitute an accessor URL outside the vault root; that is
    /// the right place to write while coordinated, but never a safe source for
    /// the catalog's relative path.
    private func makeConflictURLs(
        for coordinatedURL: URL,
        matching logicalURL: URL
    ) -> (coordinatedURL: URL, logicalURL: URL) {
        let coordinatedDirectory = coordinatedURL.deletingLastPathComponent()
        let logicalDirectory = logicalURL.deletingLastPathComponent()
        let baseName = logicalURL.deletingPathExtension().lastPathComponent
        let ext = logicalURL.pathExtension
        let timestamp = conflictTimestampFormatter.string(from: Date())

        func candidates(suffix: Int) -> (coordinatedURL: URL, logicalURL: URL) {
            let disambiguator = suffix > 1 ? " \(suffix)" : ""
            let name = "\(baseName) (conflict \(timestamp)\(disambiguator)).\(ext)"
            return (
                coordinatedDirectory.appendingPathComponent(name),
                logicalDirectory.appendingPathComponent(name)
            )
        }

        var suffix = 1
        var result = candidates(suffix: suffix)
        while fileManager.fileExists(atPath: result.coordinatedURL.path) {
            suffix += 1
            result = candidates(suffix: suffix)
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
