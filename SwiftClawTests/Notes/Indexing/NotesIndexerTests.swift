import Foundation
import Testing
@testable import SwiftClaw

private actor FakeNoteStore {
    private var snapshots: [String: NoteFileSnapshot] = [:]
    private var reads = 0

    func set(_ path: String, content: String, modifiedAt: Date) {
        snapshots[path] = NoteFileSnapshot(relativePath: path, content: content, sha256: Self.hash(content), modifiedAt: modifiedAt)
    }

    func remove(_ path: String) {
        snapshots.removeValue(forKey: path)
    }

    func read(_ path: String) throws -> NoteFileSnapshot {
        reads += 1
        guard let snapshot = snapshots[path] else { throw TestError.missing }
        return snapshot
    }

    func readCount() -> Int { reads }

    func catalog() -> [NoteSummary] {
        snapshots.values.map { NoteSummary(snapshot: $0) }.sorted { $0.relativePath < $1.relativePath }
    }

    /// A stable, deterministic stand-in for a real content hash — the
    /// indexer only ever compares it for equality, never recomputes it.
    static func hash(_ content: String) -> String {
        "h-\(content.hashValue)"
    }

    enum TestError: Error { case missing }
}

/// A deterministic, always-available stand-in for `NLSentenceEmbeddingProvider`
/// — real `NLEmbedding` model availability varies by OS/locale, which these
/// tests must not depend on.
nonisolated private struct StubEmbeddingProvider: TextEmbeddingProvider {
    let modelID = "stub-embedding-model"

    func embed(_ text: String) async -> [Float]? {
        [Float(text.count)]
    }
}

@Suite
struct NotesIndexerTests {
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeIndexer(
        store: FakeNoteStore, embeddingProvider: TextEmbeddingProvider? = nil
    ) throws -> (indexer: NotesIndexer, searchIndex: SearchIndex, linkGraph: NoteLinkGraph) {
        let searchIndex = try SearchIndex(path: ":memory:")
        let linkGraph = try NoteLinkGraph(path: ":memory:")
        let indexer = NotesIndexer(
            searchIndex: searchIndex, linkGraph: linkGraph, embeddingProvider: embeddingProvider,
            noteReader: { path in try await store.read(path) },
            catalogProvider: { await store.catalog() }
        )
        return (indexer, searchIndex, linkGraph)
    }

    @Test func addedNoteIsIndexedAndSearchable() async throws {
        let store = FakeNoteStore()
        await store.set("Note.md", content: "# Title\n\nHello world content.", modifiedAt: Self.epoch)
        let (indexer, searchIndex, _) = try makeIndexer(store: store)

        let outcome = await indexer.apply(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))
        #expect(outcome.indexed == 1)
        #expect(outcome.failedPaths.isEmpty)

        let hits = try await searchIndex.ftsSearch(query: "world")
        #expect(hits.count == 1)
        #expect(hits[0].document.sourceID == "Note.md")
    }

    @Test func unchangedHashShortCircuitsReindexing() async throws {
        let store = FakeNoteStore()
        await store.set("Note.md", content: "Same content forever.", modifiedAt: Self.epoch)
        let (indexer, searchIndex, _) = try makeIndexer(store: store)

        await indexer.apply(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))
        let firstDocument = try await searchIndex.document(sourceType: NotesIndexer.sourceType, sourceID: "Note.md")

        // Same content, different mtime — a real reconciler rescan could
        // report this as "modified" off a touch alone.
        await store.set("Note.md", content: "Same content forever.", modifiedAt: Self.epoch.addingTimeInterval(3600))
        await indexer.apply(delta: .init(added: [], modified: ["Note.md"], removed: [], renamedPairs: []))
        let secondDocument = try await searchIndex.document(sourceType: NotesIndexer.sourceType, sourceID: "Note.md")

        #expect(firstDocument?.updatedAt == secondDocument?.updatedAt)
    }

    @Test func catalogSyncSkipsReadingAFileWhoseIndexedHashMatchesItsSummary() async throws {
        let store = FakeNoteStore()
        await store.set("Note.md", content: "Same content forever.", modifiedAt: Self.epoch)
        let (indexer, _, _) = try makeIndexer(store: store)
        await indexer.apply(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))
        #expect(await store.readCount() == 1)

        let outcome = await indexer.syncCatalog(await store.catalog())

        #expect(outcome.indexed == 1)
        #expect(await store.readCount() == 1)
    }

    /// Deletions and renames made while the app was closed never arrive as
    /// a delta; reopening the persisted caches and syncing the complete
    /// catalog must drop the stale entries from both stores.
    @Test func catalogSyncAfterReopeningPersistedCachesDropsOfflineDeletionsAndRenames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexPath = directory.appendingPathComponent("index.sqlite").path
        let linksPath = directory.appendingPathComponent("links.sqlite").path

        let store = FakeNoteStore()
        await store.set("Deleted.md", content: "walrus secrets [[Target]]", modifiedAt: Self.epoch)
        await store.set("Old Name.md", content: "narwhal facts [[Target]]", modifiedAt: Self.epoch)
        await store.set("Target.md", content: "the target", modifiedAt: Self.epoch)
        do {
            let indexer = NotesIndexer(
                searchIndex: try SearchIndex(path: indexPath), linkGraph: try NoteLinkGraph(path: linksPath),
                noteReader: { path in try await store.read(path) }, catalogProvider: { await store.catalog() }
            )
            await indexer.syncCatalog(await store.catalog())
        }

        // While the app is closed: one note deleted, one renamed.
        await store.remove("Deleted.md")
        await store.remove("Old Name.md")
        await store.set("New Name.md", content: "narwhal facts [[Target]]", modifiedAt: Self.epoch)

        let searchIndex = try SearchIndex(path: indexPath)
        let linkGraph = try NoteLinkGraph(path: linksPath)
        let indexer = NotesIndexer(
            searchIndex: searchIndex, linkGraph: linkGraph,
            noteReader: { path in try await store.read(path) }, catalogProvider: { await store.catalog() }
        )
        let outcome = await indexer.syncCatalog(await store.catalog())

        #expect(outcome.removed == 2)
        #expect(try await searchIndex.ftsSearch(query: "walrus").isEmpty)
        #expect(try await searchIndex.ftsSearch(query: "narwhal").map(\.document.sourceID) == ["New Name.md"])
        #expect(try await linkGraph.backlinks(to: "Target.md").map(\.sourcePath) == ["New Name.md"])
        #expect(try await searchIndex.sourceIDs(sourceType: NotesIndexer.sourceType) == ["New Name.md", "Target.md"])
    }

    @Test func modifiedContentReindexes() async throws {
        let store = FakeNoteStore()
        await store.set("Note.md", content: "original alpha content", modifiedAt: Self.epoch)
        let (indexer, searchIndex, _) = try makeIndexer(store: store)
        await indexer.apply(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))

        await store.set("Note.md", content: "replacement beta content", modifiedAt: Self.epoch.addingTimeInterval(60))
        await indexer.apply(delta: .init(added: [], modified: ["Note.md"], removed: [], renamedPairs: []))

        let staleHits = try await searchIndex.ftsSearch(query: "alpha")
        let freshHits = try await searchIndex.ftsSearch(query: "beta")
        #expect(staleHits.isEmpty)
        #expect(freshHits.count == 1)
    }

    @Test func removedNoteDropsFromIndexAndLinkGraph() async throws {
        let store = FakeNoteStore()
        await store.set("Note.md", content: "Links to [[Other]].", modifiedAt: Self.epoch)
        let (indexer, searchIndex, linkGraph) = try makeIndexer(store: store)
        await indexer.apply(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))

        await store.remove("Note.md")
        let outcome = await indexer.apply(delta: .init(added: [], modified: [], removed: ["Note.md"], renamedPairs: []))
        #expect(outcome.removed == 1)

        let document = try await searchIndex.document(sourceType: NotesIndexer.sourceType, sourceID: "Note.md")
        #expect(document == nil)
        let links = try await linkGraph.links(forSource: "Note.md")
        #expect(links.isEmpty)
    }

    @Test func renameIsRemoveOldPlusIndexNew() async throws {
        let store = FakeNoteStore()
        await store.set("Old.md", content: "Some content about foxes.", modifiedAt: Self.epoch)
        let (indexer, searchIndex, _) = try makeIndexer(store: store)
        await indexer.apply(delta: .init(added: ["Old.md"], modified: [], removed: [], renamedPairs: []))

        await store.remove("Old.md")
        await store.set("New.md", content: "Some content about foxes.", modifiedAt: Self.epoch.addingTimeInterval(10))
        let outcome = await indexer.apply(
            delta: .init(added: [], modified: [], removed: [], renamedPairs: [.init(from: "Old.md", to: "New.md")])
        )
        #expect(outcome.indexed == 1)

        #expect(try await searchIndex.document(sourceType: NotesIndexer.sourceType, sourceID: "Old.md") == nil)
        #expect(try await searchIndex.document(sourceType: NotesIndexer.sourceType, sourceID: "New.md") != nil)
    }

    @Test func rebuildAllReindexesTheEntireCatalog() async throws {
        let store = FakeNoteStore()
        await store.set("A.md", content: "alpha content here", modifiedAt: Self.epoch)
        await store.set("B.md", content: "beta content here", modifiedAt: Self.epoch)
        let (indexer, searchIndex, _) = try makeIndexer(store: store)
        await indexer.apply(delta: .init(added: ["A.md", "B.md"], modified: [], removed: [], renamedPairs: []))

        let outcome = try await indexer.rebuildAll()
        #expect(outcome.indexed == 2)
        #expect(outcome.failedPaths.isEmpty)

        let hits = try await searchIndex.ftsSearch(query: "content")
        #expect(hits.count == 2)
        #expect(await indexer.currentFreshness().lastRunWasRebuild == true)
    }

    @Test func unreadableNoteIsSkippedWithoutCorruptingTheRestOfTheDelta() async throws {
        let store = FakeNoteStore()
        await store.set("Good.md", content: "readable content", modifiedAt: Self.epoch)
        // "Missing.md" is never set in the store, simulating a note removed
        // concurrently with the reconciler's rescan.
        let (indexer, searchIndex, _) = try makeIndexer(store: store)

        let outcome = await indexer.apply(delta: .init(added: ["Good.md", "Missing.md"], modified: [], removed: [], renamedPairs: []))
        #expect(outcome.indexed == 1)
        #expect(outcome.failedPaths == ["Missing.md"])
        #expect(try await searchIndex.document(sourceType: NotesIndexer.sourceType, sourceID: "Good.md") != nil)
    }

    @Test func searchReturnsHybridHitsForIndexedNotes() async throws {
        let store = FakeNoteStore()
        await store.set("Note.md", content: "# Title\n\nSomething about narwhals.", modifiedAt: Self.epoch)
        let (indexer, _, _) = try makeIndexer(store: store)
        await indexer.apply(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))

        let hits = try await indexer.search(query: "narwhals")
        #expect(hits.count == 1)
        #expect(hits[0].document.sourceID == "Note.md")
    }

    @Test func backlinksAndBrokenLinksReflectTheCurrentGraph() async throws {
        let store = FakeNoteStore()
        await store.set("A.md", content: "Links to [[B]] and [[Missing]].", modifiedAt: Self.epoch)
        await store.set("B.md", content: "No outgoing links here.", modifiedAt: Self.epoch)
        let (indexer, _, _) = try makeIndexer(store: store)
        await indexer.apply(delta: .init(added: ["A.md", "B.md"], modified: [], removed: [], renamedPairs: []))

        let backlinks = try await indexer.backlinks(to: "B.md")
        #expect(backlinks.map(\.sourcePath) == ["A.md"])

        let broken = try await indexer.brokenLinks()
        #expect(broken.map(\.pagePath) == ["Missing"])

        let outgoing = try await indexer.outgoingLinks(from: "A.md")
        #expect(Set(outgoing.map(\.pagePath)) == ["B", "Missing"])
    }

    @Test func settingEmbeddingProviderFromNilRebuildsSoExistingNotesGainEmbeddings() async throws {
        let store = FakeNoteStore()
        await store.set("Note.md", content: "already indexed before embeddings were enabled", modifiedAt: Self.epoch)
        let (indexer, _, _) = try makeIndexer(store: store)
        await indexer.apply(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))
        // Unchanged content would normally short-circuit re-indexing, so
        // enabling embeddings must force a rebuild rather than rely on a
        // future edit to pick up an embedding.
        let outcome = await indexer.setEmbeddingProvider(StubEmbeddingProvider())
        #expect(outcome?.indexed == 1)
        #expect(await indexer.currentFreshness().lastRunWasRebuild == true)
    }

    @Test func settingEmbeddingProviderToNilDoesNotRebuild() async throws {
        let store = FakeNoteStore()
        await store.set("Note.md", content: "content", modifiedAt: Self.epoch)
        let (indexer, _, _) = try makeIndexer(store: store, embeddingProvider: StubEmbeddingProvider())
        await indexer.apply(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))

        let outcome = await indexer.setEmbeddingProvider(nil)
        #expect(outcome == nil)
    }

    @Test func codeFencedWikilinkIsNotExtractedIntoTheLinkGraph() async throws {
        let store = FakeNoteStore()
        await store.set(
            "Note.md",
            content: """
            Real link: [[RealTarget]]

            ```
            Not a real link: [[NotACode]]
            ```
            """,
            modifiedAt: Self.epoch
        )
        let (indexer, _, linkGraph) = try makeIndexer(store: store)
        await indexer.apply(delta: .init(added: ["Note.md"], modified: [], removed: [], renamedPairs: []))

        let links = try await linkGraph.links(forSource: "Note.md")
        #expect(links.map(\.pagePath) == ["RealTarget"])
    }
}
