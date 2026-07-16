import Foundation
import Testing
@testable import SwiftClaw

@Suite(.serialized)
struct NotesPerformanceTests {
    private static let noteCount = 5_000
    private static let rebuildBudget: TimeInterval = 30
    private static let warmSearchCeiling: TimeInterval = 2
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private enum FixtureError: Error { case missingNote(String) }

    /// Generated before either stopwatch starts so these checks measure the
    /// indexer and SQLite work, not fixture string/dictionary construction.
    private static func makeFixture() -> (snapshots: [String: NoteFileSnapshot], catalog: [NoteSummary]) {
        var snapshots: [String: NoteFileSnapshot] = [:]
        snapshots.reserveCapacity(noteCount)
        var catalog: [NoteSummary] = []
        catalog.reserveCapacity(noteCount)

        for index in 0..<noteCount {
            let path = String(format: "Generated/Note-%04d.md", index)
            let uniqueToken = String(format: "projecttoken%04d", index)
            let content = """
                # Generated Note \(index)

                Deterministic fixture content for \(uniqueToken).
                Shared searchable phrase: phase seven performance fixture.
                Links to [[Generated/Note-\(String(format: "%04d", (index + 1) % noteCount))]].
                #generated #bucket\(index % 20)
                """
            let snapshot = NoteFileSnapshot(
                relativePath: path,
                content: content,
                sha256: "generated-hash-\(index)",
                modifiedAt: epoch.addingTimeInterval(TimeInterval(index))
            )
            snapshots[path] = snapshot
            catalog.append(NoteSummary(snapshot: snapshot))
        }
        return (snapshots, catalog)
    }

    @Test func generatedFiveThousandNoteRebuildAndWarmSearchStayWithinBudgets() async throws {
        let fixture = Self.makeFixture()
        #expect(fixture.snapshots.count == Self.noteCount)
        #expect(fixture.catalog.count == Self.noteCount)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftClaw-NotesPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let searchIndex = try SearchIndex(path: directory.appendingPathComponent("search.sqlite").path)
        let linkGraph = try NoteLinkGraph(path: directory.appendingPathComponent("links.sqlite").path)
        let snapshots = fixture.snapshots
        let catalog = fixture.catalog
        let indexer = NotesIndexer(
            searchIndex: searchIndex,
            linkGraph: linkGraph,
            embeddingProvider: nil,
            noteReader: { path in
                guard let snapshot = snapshots[path] else { throw FixtureError.missingNote(path) }
                return snapshot
            },
            catalogProvider: { catalog }
        )

        // Phase 7's documented performance budget is a complete 5,000-note
        // disposable-index rebuild in under 30 seconds.
        let rebuildStart = Date()
        let outcome = try await indexer.rebuildAll()
        let rebuildElapsed = Date().timeIntervalSince(rebuildStart)

        #expect(outcome.indexed == Self.noteCount)
        #expect(outcome.removed == 0)
        #expect(outcome.failedPaths.isEmpty)
        #expect(rebuildElapsed < Self.rebuildBudget)
        #expect(try await searchIndex.document(sourceType: NotesIndexer.sourceType, sourceID: "Generated/Note-0000.md") != nil)
        #expect(try await searchIndex.document(sourceType: NotesIndexer.sourceType, sourceID: "Generated/Note-4999.md") != nil)

        let queries = ["projecttoken0042", "projecttoken2500", "projecttoken4999"]
        _ = try await indexer.search(query: queries[0], limit: 10) // Warm schema, statements, and filesystem cache.

        for query in queries {
            let searchStart = Date()
            let hits = try await indexer.search(query: query, limit: 10)
            let searchElapsed = Date().timeIntervalSince(searchStart)

            #expect(hits.count == 1)
            #expect(hits.first?.document.sourceID.hasSuffix(String(query.suffix(4)) + ".md") == true)
            #expect(searchElapsed < Self.warmSearchCeiling)
        }
    }
}
