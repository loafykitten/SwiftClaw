import Foundation
import Testing
@testable import SwiftClaw

struct HybridSearcherTests {
    private func makeDocument(id: Int64) -> SearchIndex.Document {
        SearchIndex.Document(
            id: id, sourceType: "note", sourceID: "doc-\(id)", title: "Doc \(id)",
            uri: "file:///doc-\(id).md", contentHash: "hash-\(id)", updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeChunk(id: Int64, documentID: Int64, content: String = "content") -> SearchIndex.Chunk {
        SearchIndex.Chunk(
            id: id, documentID: documentID, ordinal: 0, headingPath: "Heading",
            byteStart: 0, byteEnd: content.utf8.count, content: content
        )
    }

    @Test func rrfSumsContributionsFromBothRankingsForASharedChunk() {
        let document = makeDocument(id: 1)
        let chunk = makeChunk(id: 10, documentID: 1)
        let ftsHits = [SearchIndex.FTSHit(document: document, chunk: chunk, rank: 0)]
        let vectorHits = [SearchIndex.VectorHit(document: document, chunk: chunk, similarity: 0.9)]

        let fused = HybridSearcher.fuse(ftsHits: ftsHits, vectorHits: vectorHits)

        #expect(fused.count == 1)
        let expectedScore = 1.0 / 61.0 + 1.0 / 61.0
        #expect(abs(fused[0].score - expectedScore) < 1e-9)
    }

    @Test func chunkRankedFirstInBothListsOutranksAChunkInOnlyOneList() {
        let document = makeDocument(id: 1)
        let sharedChunk = makeChunk(id: 10, documentID: 1)
        let ftsOnlyChunk = makeChunk(id: 20, documentID: 1)

        let ftsHits = [
            SearchIndex.FTSHit(document: document, chunk: sharedChunk, rank: 0),
            SearchIndex.FTSHit(document: document, chunk: ftsOnlyChunk, rank: 1),
        ]
        let vectorHits = [SearchIndex.VectorHit(document: document, chunk: sharedChunk, similarity: 0.9)]

        let fused = HybridSearcher.fuse(ftsHits: ftsHits, vectorHits: vectorHits)

        #expect(fused.map(\.chunk.id) == [10, 20])
    }

    @Test func tiesBreakByAscendingChunkIDForDeterministicOrder() {
        let document = makeDocument(id: 1)
        let chunkA = makeChunk(id: 5, documentID: 1)
        let chunkB = makeChunk(id: 2, documentID: 1)
        // Both chunks appear at rank 1 in disjoint lists, so their RRF
        // scores are identical; only the id tie-break decides order.
        let ftsHits = [SearchIndex.FTSHit(document: document, chunk: chunkA, rank: 0)]
        let vectorHits = [SearchIndex.VectorHit(document: document, chunk: chunkB, similarity: 0.5)]

        let fused = HybridSearcher.fuse(ftsHits: ftsHits, vectorHits: vectorHits)

        #expect(fused.map(\.chunk.id) == [2, 5])
    }

    @Test func respectsTheLimitAfterFusion() {
        let document = makeDocument(id: 1)
        let chunks = (0..<5).map { makeChunk(id: Int64($0), documentID: 1) }
        let ftsHits = chunks.enumerated().map { SearchIndex.FTSHit(document: document, chunk: $0.element, rank: Double($0.offset)) }

        let fused = HybridSearcher.fuse(ftsHits: ftsHits, vectorHits: [], limit: 2)

        #expect(fused.count == 2)
        #expect(fused.map(\.chunk.id) == [0, 1])
    }

    @Test func snippetTruncatesLongContentWithAnEllipsis() {
        let longContent = String(repeating: "a", count: 300)
        let snippet = HybridSearcher.snippet(from: longContent, maxLength: 50)
        #expect(snippet.count == 51)
        #expect(snippet.hasSuffix("…"))
    }

    @Test func snippetLeavesShortContentUnchanged() {
        let snippet = HybridSearcher.snippet(from: "short", maxLength: 50)
        #expect(snippet == "short")
    }
}
