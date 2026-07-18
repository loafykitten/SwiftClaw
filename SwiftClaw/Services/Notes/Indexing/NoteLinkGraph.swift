import Foundation

/// A wikilink/embed row as read back from the graph, resolved against the
/// vault's *current* note paths at query time (never cached) — so renaming
/// or removing a note never leaves other notes' stored links pointing at a
/// resolution computed against stale state.
struct ResolvedLink: Sendable, Equatable {
    let sourcePath: String
    let kind: WikilinkKind
    let pagePath: String
    let heading: String?
    let alias: String?
    /// The relative path of the note this link resolves to, or `nil` when
    /// unresolved (no match, or an ambiguous stem with no exact-path match).
    let resolvedPath: String?
}

/// Backlinks/tags graph for a vault, backed by a companion SQLite database
/// (a separate file from `SearchIndex`'s, in the same per-vault Index
/// directory — see `NotesIndexer.makeAtVaultIndexDirectory`). An **actor**
/// for the same reason `SearchIndex` is: the single `SQLiteDatabase`
/// connection is actor-confined state.
///
/// Resolution is deterministic and always computed fresh from the `notes`
/// table (the vault's current known relative paths, kept in step by
/// `NotesIndexer`): an exact match on `normalizedPath` wins; if that's
/// ambiguous (two current notes normalize to the same path — only possible
/// on a case-sensitive filesystem) the link is left unresolved rather than
/// guessing. Failing that, a *unique* filename-stem match resolves; an
/// ambiguous stem is also left unresolved. A same-note heading link
/// (`[[#Heading]]`, empty `pagePath`) always resolves to its own source note.
actor NoteLinkGraph {
    private static let schemaVersion: Int32 = 1

    private let database: SQLiteDatabase
    private var schemaReady = false

    init(path: String) throws {
        database = try SQLiteDatabase(path: path)
    }

    /// Replaces every link/tag row for `path` transactionally and ensures
    /// `path` is present in the `notes` table (so it becomes resolvable by
    /// other notes' links). Callers pass already-scanned occurrences —
    /// this type does no parsing of its own.
    func replaceLinksAndTags(forNote path: String, links: [WikilinkOccurrence], tags: [String]) async throws {
        try await ensureSchema()
        try await database.execute("BEGIN;")
        do {
            try await database.execute("INSERT OR IGNORE INTO notes (path) VALUES (?);", params: [.text(path)])
            try await database.execute("DELETE FROM links WHERE source_path = ?;", params: [.text(path)])
            for link in links {
                try await database.execute(
                    """
                    INSERT INTO links (source_path, kind, page_path, heading, alias, normalized_path, normalized_stem)
                    VALUES (?, ?, ?, ?, ?, ?, ?);
                    """,
                    params: [
                        .text(path), .text(link.kind.rawValue), .text(link.pagePath),
                        link.heading.map(SQLiteValue.text) ?? .null, link.alias.map(SQLiteValue.text) ?? .null,
                        .text(link.normalizedPath), .text(link.normalizedStem),
                    ]
                )
            }
            try await database.execute("DELETE FROM tags WHERE source_path = ?;", params: [.text(path)])
            for tag in Set(tags) {
                try await database.execute(
                    "INSERT OR IGNORE INTO tags (source_path, tag) VALUES (?, ?);",
                    params: [.text(path), .text(tag)]
                )
            }
            try await database.execute("COMMIT;")
        } catch {
            try? await database.execute("ROLLBACK;")
            throw error
        }
    }

    /// Removes `path` from the `notes` table and drops its own links/tags.
    /// Other notes' links that used to resolve to `path` are left as-is
    /// (not re-scanned) — they'll simply resolve to `nil` the next time
    /// they're queried, since resolution is always computed against the
    /// current `notes` table, never cached.
    func removeNote(_ path: String) async throws {
        try await ensureSchema()
        try await database.execute("BEGIN;")
        do {
            try await database.execute("DELETE FROM notes WHERE path = ?;", params: [.text(path)])
            try await database.execute("DELETE FROM links WHERE source_path = ?;", params: [.text(path)])
            try await database.execute("DELETE FROM tags WHERE source_path = ?;", params: [.text(path)])
            try await database.execute("COMMIT;")
        } catch {
            try? await database.execute("ROLLBACK;")
            throw error
        }
    }

    /// Wipes all notes/links/tags back to empty — the graph is a
    /// rebuildable cache, same contract as `SearchIndex.rebuild()`.
    func rebuild() async throws {
        try await ensureSchema()
        try await database.execute("DELETE FROM notes;")
        try await database.execute("DELETE FROM links;")
        try await database.execute("DELETE FROM tags;")
    }

    /// All outgoing links from `path`, resolved against the current vault state.
    func links(forSource path: String) async throws -> [ResolvedLink] {
        try await ensureSchema()
        let resolutionIndex = try await resolutionIndex()
        let rows = try await database.query(
            "SELECT source_path, kind, page_path, heading, alias, normalized_path, normalized_stem FROM links WHERE source_path = ?;",
            params: [.text(path)]
        )
        return try rows.map { try Self.decode(row: $0, resolutionIndex: resolutionIndex) }
    }

    /// Every link, from any note, that resolves to `path` — the reverse
    /// query `BacklinksPanel` needs.
    func backlinks(to path: String) async throws -> [ResolvedLink] {
        try await allResolvedLinks().filter { $0.resolvedPath == path }
    }

    /// Every link that fails to resolve against the current vault state.
    func brokenLinks() async throws -> [ResolvedLink] {
        try await allResolvedLinks().filter { $0.resolvedPath == nil }
    }

    /// All tags currently recorded for `path` (front matter + body, deduped).
    func tags(forSource path: String) async throws -> [String] {
        try await ensureSchema()
        let rows = try await database.query("SELECT tag FROM tags WHERE source_path = ? ORDER BY tag;", params: [.text(path)])
        return rows.compactMap { row -> String? in
            guard case .text(let tag)? = row.first else { return nil }
            return tag
        }
    }

    // MARK: - Resolution

    private func allResolvedLinks() async throws -> [ResolvedLink] {
        try await ensureSchema()
        let resolutionIndex = try await resolutionIndex()
        let rows = try await database.query(
            "SELECT source_path, kind, page_path, heading, alias, normalized_path, normalized_stem FROM links;"
        )
        return try rows.map { try Self.decode(row: $0, resolutionIndex: resolutionIndex) }
    }

    private struct ResolutionIndex {
        var exactPaths: [String: [String]] = [:]
        var stems: [String: [String]] = [:]
    }

    /// Query-local dictionaries are rebuilt from the current `notes` table,
    /// so path changes invalidate resolution without retaining stale state.
    private func resolutionIndex() async throws -> ResolutionIndex {
        let rows = try await database.query("SELECT path FROM notes;")
        var index = ResolutionIndex()
        index.exactPaths.reserveCapacity(rows.count)
        index.stems.reserveCapacity(rows.count)
        for row in rows {
            guard case .text(let path)? = row.first else { continue }
            let normalizedPath = WikilinkScanner.normalize(path: path)
            index.exactPaths[normalizedPath, default: []].append(path)
            index.stems[WikilinkScanner.stem(ofNormalizedPath: normalizedPath), default: []].append(path)
        }
        return index
    }

    private static func decode(row: [SQLiteValue], resolutionIndex: ResolutionIndex) throws -> ResolvedLink {
        guard row.count == 7,
              case .text(let sourcePath) = row[0], case .text(let kindRaw) = row[1], case .text(let pagePath) = row[2],
              case .text(let normalizedPath) = row[5], case .text(let normalizedStem) = row[6],
              let kind = WikilinkKind(rawValue: kindRaw)
        else {
            throw NoteLinkGraphError.malformedRow
        }
        let heading: String? = { if case .text(let value) = row[3] { return value } else { return nil } }()
        let alias: String? = { if case .text(let value) = row[4] { return value } else { return nil } }()
        let resolvedPath = resolve(
            normalizedPath: normalizedPath, normalizedStem: normalizedStem,
            sourcePath: sourcePath, resolutionIndex: resolutionIndex
        )
        return ResolvedLink(
            sourcePath: sourcePath, kind: kind, pagePath: pagePath, heading: heading, alias: alias, resolvedPath: resolvedPath
        )
    }

    /// Exact normalized-path match wins if unambiguous; otherwise a unique
    /// filename-stem match; otherwise unresolved. Never guesses between
    /// multiple equally-plausible candidates.
    private static func resolve(
        normalizedPath: String,
        normalizedStem: String,
        sourcePath: String,
        resolutionIndex: ResolutionIndex
    ) -> String? {
        guard !normalizedPath.isEmpty else { return sourcePath }

        let exactMatches = resolutionIndex.exactPaths[normalizedPath] ?? []
        if exactMatches.count == 1 { return exactMatches[0] }
        guard exactMatches.isEmpty else { return nil }

        let stemMatches = resolutionIndex.stems[normalizedStem] ?? []
        return stemMatches.count == 1 ? stemMatches[0] : nil
    }

    // MARK: - Schema

    private func ensureSchema() async throws {
        guard !schemaReady else { return }
        let version = try await database.currentUserVersion()
        if version < Self.schemaVersion {
            try await database.execute("CREATE TABLE IF NOT EXISTS notes (path TEXT PRIMARY KEY);")
            try await database.execute(
                """
                CREATE TABLE IF NOT EXISTS links (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_path TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    page_path TEXT NOT NULL,
                    heading TEXT,
                    alias TEXT,
                    normalized_path TEXT NOT NULL,
                    normalized_stem TEXT NOT NULL
                );
                """
            )
            try await database.execute("CREATE INDEX IF NOT EXISTS idx_links_source_path ON links(source_path);")
            try await database.execute(
                """
                CREATE TABLE IF NOT EXISTS tags (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_path TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    UNIQUE(source_path, tag)
                );
                """
            )
            try await database.setUserVersion(Self.schemaVersion)
        }
        schemaReady = true
    }
}

enum NoteLinkGraphError: LocalizedError, Equatable {
    case malformedRow

    var errorDescription: String? {
        "The link graph returned a row in an unexpected shape."
    }
}
