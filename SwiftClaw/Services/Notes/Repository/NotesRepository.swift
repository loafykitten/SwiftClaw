import Foundation

/// Stable, in-memory catalog entry for one vault note. Identity is
/// `relativePath` — never `title` — so a rename produces a *new* identity
/// (matches the vault: renaming is a path change, not a content change) and
/// two notes may share a display title without colliding.
struct NoteSummary: Identifiable, Equatable, Sendable {
    var id: String { relativePath }
    let relativePath: String
    let title: String
    let sha256: String
    let modifiedAt: Date

    init(relativePath: String, title: String, sha256: String, modifiedAt: Date) {
        self.relativePath = relativePath
        self.title = title
        self.sha256 = sha256
        self.modifiedAt = modifiedAt
    }

    init(snapshot: NoteFileSnapshot) {
        self.init(
            relativePath: snapshot.relativePath,
            title: Self.title(forRelativePath: snapshot.relativePath),
            sha256: snapshot.sha256,
            modifiedAt: snapshot.modifiedAt
        )
    }

    /// Display title derived from the filename alone (last path component,
    /// extension stripped) — never persisted back to the file and never
    /// treated as identity.
    static func title(forRelativePath relativePath: String) -> String {
        let name = (relativePath as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }
}

/// Sanitizes user-facing input (a requested title, an optional subfolder)
/// into vault-safe path components. Pure and side-effect free so the
/// collision/sanitization rules are unit-testable without a vault.
enum NotesFilenameSanitizer {
    static let untitledFallback = "Untitled"

    /// Strips path separators and control characters, trims whitespace, and
    /// trims leading dots (a dot-prefixed filename would be invisible to
    /// `NotesVault.enumerate()` per `VaultIgnoreRules`). Falls back to
    /// `untitledFallback` when nothing usable remains.
    static func sanitizeTitle(_ rawTitle: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let filtered = String(rawTitle.unicodeScalars.filter { !disallowed.contains($0) })
        var sanitized = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.hasPrefix(".") {
            sanitized.removeFirst()
        }
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? untitledFallback : sanitized
    }

    /// Validates a caller-supplied subfolder hint: relative, no `.`/`..`
    /// traversal, no leading-slash escape, no dot-prefixed component (which
    /// `VaultIgnoreRules` would make invisible). Returns `nil` (vault root)
    /// rather than throwing when the input isn't safe — an untrusted or
    /// stale folder hint shouldn't fail note creation.
    static func sanitizeFolder(_ rawFolder: String?) -> String? {
        guard let rawFolder else { return nil }
        let trimmed = rawFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") })
        else { return nil }
        return components.joined(separator: "/")
    }
}

/// Single mutation boundary for the Notes vault (the `ReminderRepository`
/// pattern): every create/save/rename/delete a UI or tool needs goes through
/// here, never straight at `NotesVault`. Owns the in-memory `[NoteSummary]`
/// catalog so list UIs never wait on a vault round trip, and posts
/// `.notesStoreDidChange` after every actual catalog mutation so interested
/// views/services can react without polling.
@MainActor
final class NotesRepository {
    private static let logger = AppLog.make("notes.repository")
    private static let maxCreateAttempts = 1000

    private let vault: NotesVault
    private let revisionStore: NoteRevisionStore

    private(set) var notes: [NoteSummary] = []
    private(set) var isLoading = false
    private(set) var lastError: NotesError?

    init(vault: NotesVault, revisionStore: NoteRevisionStore) {
        self.vault = vault
        self.revisionStore = revisionStore
    }

    func summary(forRelativePath relativePath: String) -> NoteSummary? {
        notes.first { $0.relativePath == relativePath }
    }

    /// Reads a single note's current on-disk content — the only sanctioned
    /// way for a view (e.g. the Notes editor loading a selection) to see
    /// note content, so callers never reach past this repository to touch
    /// `NotesVault` directly.
    func read(relativePath: String) async throws -> NoteFileSnapshot {
        do {
            return try await vault.read(relativePath: relativePath)
        } catch {
            throw NotesError.from(error)
        }
    }

    /// Reads a relative asset's raw bytes (e.g. an image a note embeds) —
    /// the only sanctioned way for reading-mode rendering to load one, so
    /// renderers never reach past this repository to touch `NotesVault` or
    /// `FileManager` directly.
    func readData(relativePath: String) async throws -> Data {
        do {
            return try await vault.readData(relativePath: relativePath)
        } catch {
            throw NotesError.from(error)
        }
    }

    // MARK: - Bootstrap / reload

    /// Rebuilds the catalog from scratch by enumerating and reading every
    /// note in the vault. Deliberately **never** posts `.notesStoreDidChange`
    /// — this is initial hydration, not a mutation a subscriber needs to
    /// react to, and it doubles as the baseline a reconciler's first
    /// (empty-`knownState`) full scan would otherwise re-report as an
    /// "added" delta for every file already folded in here. Callers driving
    /// a `VaultReconciler` should call this once before wiring up
    /// `apply(delta:)`, not feed its first scan through `apply(delta:)`.
    ///
    /// A single unreadable or externally-removed-mid-scan note is skipped
    /// rather than failing the whole load; `lastError` surfaces the count.
    func reload() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let paths: [String]
        do {
            paths = try await vault.enumerate()
        } catch {
            lastError = NotesError.from(error)
            Self.logger.error("enumerate failed: \(String(describing: error))")
            return
        }

        var summaries: [NoteSummary] = []
        var unreadableCount = 0
        for path in paths {
            do {
                let snapshot = try await vault.read(relativePath: path)
                summaries.append(NoteSummary(snapshot: snapshot))
            } catch {
                unreadableCount += 1
                Self.logger.error("read failed during reload, skipping: \(String(describing: error))")
            }
        }

        notes = summaries.sorted { $0.relativePath < $1.relativePath }
        if unreadableCount > 0 {
            lastError = .partialLoadFailure(count: unreadableCount)
        }
    }

    // MARK: - Reconciliation

    /// Folds a reconciler delta into the catalog: renamed pairs update
    /// identity/path in place, removed paths drop their entry, and
    /// added/modified paths are re-read from the vault (never trusted from
    /// the delta's hash alone) and upserted. Posts `.notesStoreDidChange`
    /// only when the catalog actually changed.
    @discardableResult
    func apply(delta: VaultReconciler.ReconcileDelta) async -> Bool {
        guard !delta.isEmpty else { return false }

        var byPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.relativePath, $0) })
        var mutated = false

        for pair in delta.renamedPairs {
            guard let existing = byPath.removeValue(forKey: pair.from) else { continue }
            byPath[pair.to] = NoteSummary(
                relativePath: pair.to,
                title: NoteSummary.title(forRelativePath: pair.to),
                sha256: existing.sha256,
                modifiedAt: existing.modifiedAt
            )
            mutated = true
        }

        for path in delta.removed where byPath.removeValue(forKey: path) != nil {
            mutated = true
        }

        for path in delta.added + delta.modified {
            do {
                let snapshot = try await vault.read(relativePath: path)
                byPath[path] = NoteSummary(snapshot: snapshot)
                mutated = true
            } catch {
                // The path was added/modified as of the rescan but is no
                // longer readable (e.g. removed again before we got to it) —
                // drop it from this delta rather than guessing.
                Self.logger.error("delta read failed, skipping: \(String(describing: error))")
            }
        }

        guard mutated else { return false }
        notes = byPath.values.sorted { $0.relativePath < $1.relativePath }
        NotificationCenter.default.post(name: .notesStoreDidChange, object: nil)
        return true
    }

    // MARK: - Create

    /// Creates an empty note. `title` is sanitized into a filename
    /// (forbidden separators/control characters stripped, dangerous
    /// dot-prefixes trimmed, falling back to "Untitled"); `folder` is kept
    /// only when it's a safe relative subfolder. Collisions are resolved by
    /// trying " 2", " 3", … deterministically. Existence is probed via
    /// `NotesVault.exists` before each attempt so a foreseeable collision
    /// never has to fall through to `write`'s conflict-copy path; a
    /// create-only hash collision that still slips through (a race against
    /// an external writer) is *not* treated as success — it's discarded and
    /// the next candidate is tried.
    @discardableResult
    func create(title: String, folder: String? = nil) async throws -> NoteSummary {
        let baseName = NotesFilenameSanitizer.sanitizeTitle(title)
        let safeFolder = NotesFilenameSanitizer.sanitizeFolder(folder)

        var lastError: Error?
        for suffix in 1...Self.maxCreateAttempts {
            let path = Self.candidatePath(baseName: baseName, folder: safeFolder, suffix: suffix)
            do {
                let alreadyExists = try await vault.exists(relativePath: path)
                guard !alreadyExists else { continue }
                let outcome = try await vault.write(relativePath: path, content: "", expectedHash: nil)
                switch outcome {
                case .wrote(let snapshot):
                    let summary = NoteSummary(snapshot: snapshot)
                    upsert(summary)
                    NotificationCenter.default.post(name: .notesStoreDidChange, object: nil)
                    return summary
                case .conflict:
                    continue
                }
            } catch {
                lastError = error
            }
        }
        throw lastError.map(NotesError.from) ?? .createFailed(title: baseName)
    }

    private static func candidatePath(baseName: String, folder: String?, suffix: Int) -> String {
        let name = suffix == 1 ? "\(baseName).md" : "\(baseName) \(suffix).md"
        guard let folder else { return name }
        return "\(folder)/\(name)"
    }

    // MARK: - Save

    /// Snapshots the current on-disk content (if any) before every attempted
    /// content mutation, then writes with the caller's `expectedHash` guard.
    /// A hash mismatch never overwrites: the attempted content lands at a
    /// conflict-copy path (added to the catalog so it's visible) and
    /// `.externalConflict` is thrown while the original summary is left
    /// untouched.
    @discardableResult
    func save(relativePath: String, content: String, expectedHash: String?) async throws -> NoteSummary {
        do {
            let current = try await vault.read(relativePath: relativePath)
            try await revisionStore.snapshot(key: relativePath, content: current.content)
        } catch let vaultError as NotesVault.VaultError where Self.isFileNotFound(vaultError) {
            // Nothing on disk yet at this path — no pre-mutation state exists to snapshot.
        } catch {
            throw NotesError.from(error)
        }

        let outcome: NoteWriteOutcome
        do {
            outcome = try await vault.write(relativePath: relativePath, content: content, expectedHash: expectedHash)
        } catch {
            throw NotesError.from(error)
        }

        switch outcome {
        case .wrote(let snapshot):
            let summary = NoteSummary(snapshot: snapshot)
            upsert(summary)
            NotificationCenter.default.post(name: .notesStoreDidChange, object: nil)
            return summary
        case .conflict(let conflictSnapshot):
            upsert(NoteSummary(snapshot: conflictSnapshot))
            NotificationCenter.default.post(name: .notesStoreDidChange, object: nil)
            throw NotesError.externalConflict(copyPath: conflictSnapshot.relativePath)
        }
    }

    // MARK: - Rename

    /// Snapshots the pre-rename content, then moves the file (never
    /// clobbering an existing destination) and updates the catalog entry's
    /// identity/path in place.
    @discardableResult
    func rename(from relativePath: String, to newRelativePath: String) async throws -> NoteSummary {
        do {
            let current = try await vault.read(relativePath: relativePath)
            try await revisionStore.snapshot(key: relativePath, content: current.content)
        } catch {
            throw NotesError.from(error)
        }

        let renamed: NoteFileSnapshot
        do {
            renamed = try await vault.rename(from: relativePath, to: newRelativePath)
        } catch {
            throw NotesError.from(error)
        }

        var byPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.relativePath, $0) })
        byPath.removeValue(forKey: relativePath)
        let summary = NoteSummary(snapshot: renamed)
        byPath[newRelativePath] = summary
        notes = byPath.values.sorted { $0.relativePath < $1.relativePath }
        NotificationCenter.default.post(name: .notesStoreDidChange, object: nil)
        return summary
    }

    // MARK: - Delete

    /// Snapshots the pre-delete content, then moves the file to the Trash.
    /// The catalog entry is removed only once the trash move succeeds.
    func delete(relativePath: String) async throws {
        do {
            let current = try await vault.read(relativePath: relativePath)
            try await revisionStore.snapshot(key: relativePath, content: current.content)
        } catch {
            throw NotesError.from(error)
        }

        do {
            try await vault.delete(relativePath: relativePath)
        } catch {
            throw NotesError.from(error)
        }

        notes.removeAll { $0.relativePath == relativePath }
        NotificationCenter.default.post(name: .notesStoreDidChange, object: nil)
    }

    // MARK: - Helpers

    private func upsert(_ summary: NoteSummary) {
        var byPath = Dictionary(uniqueKeysWithValues: notes.map { ($0.relativePath, $0) })
        byPath[summary.relativePath] = summary
        notes = byPath.values.sorted { $0.relativePath < $1.relativePath }
    }

    private static func isFileNotFound(_ error: NotesVault.VaultError) -> Bool {
        if case .fileNotFound = error { return true }
        return false
    }
}

extension Notification.Name {
    /// Posted after every catalog-mutating `NotesRepository` operation
    /// (create/save/rename/delete/apply-delta) so interested views/services
    /// can reconcile without polling. Never posted by `reload()` — see its
    /// doc comment.
    static let notesStoreDidChange = Notification.Name("SwiftClaw.notesStoreDidChange")
}
