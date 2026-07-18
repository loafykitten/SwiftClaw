import Foundation
import os

/// Drives `SearchIndex` + `NoteLinkGraph` from vault state. Takes its
/// read/catalog access as injected `@Sendable` closures rather than a
/// `NotesRepository` reference directly: `NotesRepository` is `@MainActor`
/// and this type is an actor, and — per the plan's safety invariants — the
/// indexer must never reach around the repository to touch vault files
/// itself in production. A production caller wires `noteReader` to
/// `NotesRepository.read(relativePath:)` and `catalogProvider` to a snapshot
/// of `NotesRepository.notes`; tests wire in-memory stubs instead.
actor NotesIndexer {
    typealias NoteReader = @Sendable (String) async throws -> NoteFileSnapshot
    typealias NoteCatalogProvider = @Sendable () async -> [NoteSummary]

    /// The outcome of one `apply(delta:)` or `rebuildAll()` run. `failedPaths`
    /// is surfaced (not swallowed) so a health view can show exactly which
    /// notes didn't make it into the index, rather than reporting "healthy"
    /// over a partially-stale index.
    struct RunOutcome: Sendable, Equatable {
        let indexed: Int
        let removed: Int
        let failedPaths: [String]
    }

    /// Point-in-time index freshness, for health UI.
    struct Freshness: Sendable, Equatable {
        var lastSuccessAt: Date?
        var lastFailedPaths: [String]
        var lastRunWasRebuild: Bool

        static let initial = Freshness(lastSuccessAt: nil, lastFailedPaths: [], lastRunWasRebuild: false)
    }

    static let sourceType = "note"
    private static let logger = AppLog.make("notes.indexer")

    private let searchIndex: SearchIndex
    private let linkGraph: NoteLinkGraph
    /// `var`, not `let`: `setEmbeddingProvider(_:)` lets a caller flip this
    /// live when the user toggles `settings.notes.embeddingsEnabled`, without
    /// tearing down and rebuilding the whole indexer.
    private var embeddingProvider: TextEmbeddingProvider?
    private let noteReader: NoteReader
    private let catalogProvider: NoteCatalogProvider

    private(set) var freshness = Freshness.initial

    init(
        searchIndex: SearchIndex,
        linkGraph: NoteLinkGraph,
        embeddingProvider: TextEmbeddingProvider? = nil,
        noteReader: @escaping NoteReader,
        catalogProvider: @escaping NoteCatalogProvider
    ) {
        self.searchIndex = searchIndex
        self.linkGraph = linkGraph
        self.embeddingProvider = embeddingProvider
        self.noteReader = noteReader
        self.catalogProvider = catalogProvider
    }

    func currentFreshness() -> Freshness {
        freshness
    }

    /// Hybrid FTS+vector search over this vault's index, fused via
    /// `HybridSearcher`. Uses whichever `embeddingProvider` is currently
    /// configured (possibly `nil`, degrading to FTS-only) — always the
    /// live value, never one captured at construction time.
    func search(query: String, limit: Int = 20) async throws -> [SearchHit] {
        try await HybridSearcher(searchIndex: searchIndex, embeddingProvider: embeddingProvider).search(query: query, limit: limit)
    }

    /// Every link, from any note, that resolves to `path` — for a backlinks
    /// inspector.
    func backlinks(to path: String) async throws -> [ResolvedLink] {
        try await linkGraph.backlinks(to: path)
    }

    /// Every link that fails to resolve against the current vault state —
    /// for the health/broken-links UI.
    func brokenLinks() async throws -> [ResolvedLink] {
        try await linkGraph.brokenLinks()
    }

    /// All outgoing links from `path`, resolved against the current vault state.
    func outgoingLinks(from path: String) async throws -> [ResolvedLink] {
        try await linkGraph.links(forSource: path)
    }

    /// Swaps the embedding provider live (e.g. the user flipped
    /// `settings.notes.embeddingsEnabled` in Settings). Disabling stops
    /// vector use immediately — later `search` calls simply stop passing an
    /// embedding provider to `HybridSearcher`, degrading to FTS-only.
    /// Enabling from `nil` re-embeds every note by rebuilding the whole
    /// index: `indexNote`'s content-hash short-circuit would otherwise skip
    /// every already-indexed, unchanged note and leave it permanently
    /// FTS-only until its content next changes.
    @discardableResult
    func setEmbeddingProvider(_ provider: TextEmbeddingProvider?) async -> RunOutcome? {
        let wasEnabled = embeddingProvider != nil
        embeddingProvider = provider
        guard provider != nil, !wasEnabled else { return nil }
        return try? await rebuildAll()
    }

    /// Folds one `VaultReconciler.ReconcileDelta` into the index: a rename
    /// is handled as removing the old path's document/links and indexing
    /// the new path fresh (no in-place path rewrite, so a rename can never
    /// leave stale chunks/links behind under the old identity). Every path
    /// is handled independently — one unreadable or concurrently-removed
    /// note is recorded in `failedPaths`, never allowed to abort the rest
    /// of the delta.
    @discardableResult
    func apply(delta: VaultReconciler.ReconcileDelta) async -> RunOutcome {
        guard !delta.isEmpty else { return RunOutcome(indexed: 0, removed: 0, failedPaths: []) }

        var indexed = 0
        var removed = 0
        var failed: [String] = []

        for pair in delta.renamedPairs {
            await removeNote(pair.from)
            if await indexNote(pair.to) { indexed += 1 } else { failed.append(pair.to) }
        }
        for path in delta.removed {
            if await removeNote(path) { removed += 1 } else { failed.append(path) }
        }
        for path in delta.added + delta.modified {
            if await indexNote(path) { indexed += 1 } else { failed.append(path) }
        }

        freshness = Freshness(lastSuccessAt: Date(), lastFailedPaths: failed, lastRunWasRebuild: false)
        return RunOutcome(indexed: indexed, removed: removed, failedPaths: failed)
    }

    /// Ensures a freshly loaded catalog is present in the index without
    /// re-reading note files whose indexed hash already matches the catalog's
    /// `NoteSummary.sha256`. Catalog hashes are used only for this bootstrap
    /// path; ordinary reconciliation still reads the changed file.
    @discardableResult
    func syncCatalog(_ notes: [NoteSummary]) async -> RunOutcome {
        var indexed = 0
        var failed: [String] = []
        for note in notes {
            if await indexNote(note.relativePath, catalogHash: note.sha256) {
                indexed += 1
            } else {
                failed.append(note.relativePath)
            }
        }
        freshness = Freshness(lastSuccessAt: Date(), lastFailedPaths: failed, lastRunWasRebuild: false)
        return RunOutcome(indexed: indexed, removed: 0, failedPaths: failed)
    }

    /// Wipes both stores and reindexes every note the catalog currently
    /// knows about, from scratch — ignores content-hash short-circuiting
    /// entirely (the index is a rebuildable cache; a rebuild exists
    /// precisely to recover from a suspect one). Throws only for the wipe
    /// itself; per-note failures during the rebuild still land in
    /// `failedPaths` rather than aborting the run.
    @discardableResult
    func rebuildAll() async throws -> RunOutcome {
        try await searchIndex.rebuild()
        try await linkGraph.rebuild()

        var indexed = 0
        var failed: [String] = []
        for note in await catalogProvider() {
            if await indexNote(note.relativePath) { indexed += 1 } else { failed.append(note.relativePath) }
        }

        freshness = Freshness(lastSuccessAt: Date(), lastFailedPaths: failed, lastRunWasRebuild: true)
        return RunOutcome(indexed: indexed, removed: 0, failedPaths: failed)
    }

    /// Assembles the current `NotesHealthSummary` from this indexer's own
    /// stores: broken links and FTS/embedding availability are queried live
    /// (never cached), conflict-copy count comes from the current catalog,
    /// and index freshness comes from the last `apply(delta:)`/
    /// `rebuildAll()` run. A failure probing one dimension is surfaced in
    /// `indexError` rather than silently reported as healthy.
    func healthSummary() async -> NotesHealthSummary {
        let notes = await catalogProvider()
        let conflictCopyCount = notes.filter { NotesHealthSummary.isConflictCopy($0.relativePath) }.count

        var ftsAvailable = false
        var errors: [String] = []
        do {
            ftsAvailable = try await searchIndex.health().ftsAvailable
        } catch {
            errors.append(error.localizedDescription)
        }

        var brokenLinkCount = 0
        do {
            brokenLinkCount = try await linkGraph.brokenLinks().count
        } catch {
            errors.append(error.localizedDescription)
        }

        var embeddingAvailable = false
        if let embeddingProvider {
            embeddingAvailable = await embeddingProvider.embed(NotesHealthSummary.embeddingProbeText) != nil
        }

        return NotesHealthSummary(
            brokenLinkCount: brokenLinkCount, conflictCopyCount: conflictCopyCount, ftsAvailable: ftsAvailable,
            embeddingAvailable: embeddingAvailable, lastIndexSuccessAt: freshness.lastSuccessAt,
            lastIndexFailedPaths: freshness.lastFailedPaths, indexError: errors.isEmpty ? nil : errors.joined(separator: "; ")
        )
    }

    // MARK: - Per-note indexing

    /// Reads, parses, chunks, embeds (if a provider is configured), and
    /// upserts one note. Short-circuits on an unchanged content hash — the
    /// common case for a reconciler rescan that found no real edits, or a
    /// touch-only mtime bump.
    @discardableResult
    private func indexNote(_ relativePath: String, catalogHash: String? = nil) async -> Bool {
        do {
            if let catalogHash,
               let existing = try await searchIndex.document(sourceType: Self.sourceType, sourceID: relativePath),
               existing.contentHash == catalogHash {
                return true
            }

            let snapshot = try await noteReader(relativePath)

            if let existing = try await searchIndex.document(sourceType: Self.sourceType, sourceID: relativePath),
               existing.contentHash == snapshot.sha256 {
                return true
            }

            let document = MarkdownDocument(source: snapshot.content)
            let textChunks = TextChunker.chunk(snapshot.content)
            let chunkInputs = textChunks.enumerated().map { ordinal, chunk in
                SearchIndex.ChunkInput(
                    ordinal: ordinal, headingPath: chunk.headingPath,
                    byteStart: chunk.byteStart, byteEnd: chunk.byteEnd, content: chunk.content
                )
            }
            let documentInput = SearchIndex.DocumentInput(
                sourceType: Self.sourceType, sourceID: relativePath,
                title: NoteSummary.title(forRelativePath: relativePath), uri: "swiftclaw-note://\(relativePath)",
                contentHash: snapshot.sha256, updatedAt: snapshot.modifiedAt
            )
            let documentID = try await searchIndex.upsert(document: documentInput, chunks: chunkInputs)

            if let embeddingProvider {
                for chunk in try await searchIndex.chunks(forDocumentID: documentID) {
                    guard let vector = await embeddingProvider.embed(chunk.content) else { continue }
                    try await searchIndex.upsertEmbedding(chunkID: chunk.id, modelID: embeddingProvider.modelID, vector: vector)
                }
            }

            let links = WikilinkScanner.scan(document)
            let tags = TagScanner.scan(document).map(\.tag)
            try await linkGraph.replaceLinksAndTags(forNote: relativePath, links: links, tags: tags)
            return true
        } catch {
            Self.logger.error("index failed for \(relativePath, privacy: .public), skipping: \(String(describing: error))")
            return false
        }
    }

    @discardableResult
    private func removeNote(_ relativePath: String) async -> Bool {
        do {
            try await searchIndex.remove(sourceType: Self.sourceType, sourceID: relativePath)
            try await linkGraph.removeNote(relativePath)
            return true
        } catch {
            Self.logger.error("remove failed for \(relativePath, privacy: .public): \(String(describing: error))")
            return false
        }
    }
}

// MARK: - Factory

extension NotesIndexer {
    private static let searchIndexFilename = "index-v1.sqlite"
    private static let linkGraphFilename = "links-v1.sqlite"

    /// Builds a `NotesIndexer` wired to the per-vault database path
    /// `App Support/SwiftClaw/Notes/Index/<vaultID>/index-v1.sqlite`, plus
    /// a companion `links-v1.sqlite` in the same directory for
    /// `NoteLinkGraph`. `indexDirectory` is `VaultConfigurationStore
    /// .indexDirectory()` — this factory only creates the directory and
    /// opens the two databases; callers own everything about which vault
    /// it belongs to.
    static func makeAtVaultIndexDirectory(
        _ indexDirectory: URL,
        embeddingProvider: TextEmbeddingProvider? = nil,
        fileManager: FileManager = .default,
        noteReader: @escaping NoteReader,
        catalogProvider: @escaping NoteCatalogProvider
    ) throws -> NotesIndexer {
        try fileManager.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let searchIndex = try SearchIndex(path: indexDirectory.appendingPathComponent(searchIndexFilename).path)
        let linkGraph = try NoteLinkGraph(path: indexDirectory.appendingPathComponent(linkGraphFilename).path)
        return NotesIndexer(
            searchIndex: searchIndex, linkGraph: linkGraph, embeddingProvider: embeddingProvider,
            noteReader: noteReader, catalogProvider: catalogProvider
        )
    }
}
