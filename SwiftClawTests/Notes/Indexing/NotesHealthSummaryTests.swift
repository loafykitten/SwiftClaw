import Foundation
import Testing
@testable import SwiftClaw

nonisolated private struct StubEmbeddingProvider: TextEmbeddingProvider {
    let modelID = "stub-model"
    let result: [Float]?

    func embed(_ text: String) async -> [Float]? { result }
}

@Suite
struct NotesHealthSummaryTests {
    @Test func conflictCopyNamingConventionIsRecognized() {
        #expect(NotesHealthSummary.isConflictCopy("Note (conflict 2026-07-13 143022).md"))
        #expect(NotesHealthSummary.isConflictCopy("Folder/Note (conflict 2026-07-13 143022 2).md"))
        #expect(!NotesHealthSummary.isConflictCopy("Note.md"))
        #expect(!NotesHealthSummary.isConflictCopy("Note (draft).md"))
    }

    @Test func summaryReportsBrokenLinksConflictCountAndFreshness() async throws {
        let searchIndex = try SearchIndex(path: ":memory:")
        let linkGraph = try NoteLinkGraph(path: ":memory:")
        let notes: [String: NoteFileSnapshot] = [
            "Note.md": .init(relativePath: "Note.md", content: "Links to [[Missing]].", sha256: "h1", modifiedAt: Date()),
            "Note (conflict 2026-07-13 143022).md": .init(
                relativePath: "Note (conflict 2026-07-13 143022).md", content: "conflict copy", sha256: "h2", modifiedAt: Date()
            ),
        ]
        let indexer = NotesIndexer(
            searchIndex: searchIndex, linkGraph: linkGraph, embeddingProvider: StubEmbeddingProvider(result: [1, 2, 3]),
            noteReader: { path in
                guard let snapshot = notes[path] else { throw NSError(domain: "test", code: 1) }
                return snapshot
            },
            catalogProvider: { notes.values.map { NoteSummary(snapshot: $0) } }
        )

        await indexer.apply(delta: .init(added: Array(notes.keys), modified: [], removed: [], renamedPairs: []))

        let summary = await indexer.healthSummary()
        #expect(summary.brokenLinkCount == 1)
        #expect(summary.conflictCopyCount == 1)
        #expect(summary.embeddingAvailable == true)
        #expect(summary.lastIndexSuccessAt != nil)
        #expect(summary.lastIndexFailedPaths.isEmpty)
    }

    @Test func summaryReportsEmbeddingUnavailableWhenProviderCannotEmbed() async throws {
        let searchIndex = try SearchIndex(path: ":memory:")
        let linkGraph = try NoteLinkGraph(path: ":memory:")
        let indexer = NotesIndexer(
            searchIndex: searchIndex, linkGraph: linkGraph, embeddingProvider: StubEmbeddingProvider(result: nil),
            noteReader: { _ in throw NSError(domain: "test", code: 1) },
            catalogProvider: { [] }
        )

        let summary = await indexer.healthSummary()
        #expect(summary.embeddingAvailable == false)
    }

    @Test func summaryReportsFtsUnavailableWhenSimulated() async throws {
        let searchIndex = try SearchIndex(path: ":memory:", simulateFTS5Unavailable: true)
        let linkGraph = try NoteLinkGraph(path: ":memory:")
        let indexer = NotesIndexer(
            searchIndex: searchIndex, linkGraph: linkGraph,
            noteReader: { _ in throw NSError(domain: "test", code: 1) },
            catalogProvider: { [] }
        )

        let summary = await indexer.healthSummary()
        #expect(summary.ftsAvailable == false)
    }
}
