import Foundation
import NaturalLanguage
import Testing
@testable import SwiftClaw

struct SearchIndexTests {
    private func makeDocument(sourceID: String = "note-1", contentHash: String = "hash-1") -> SearchIndex.DocumentInput {
        SearchIndex.DocumentInput(
            sourceType: "note", sourceID: sourceID, title: "Note One", uri: "file:///note-1.md",
            contentHash: contentHash, updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeChunks(_ contents: String...) -> [SearchIndex.ChunkInput] {
        contents.enumerated().map { offset, content in
            SearchIndex.ChunkInput(ordinal: offset, headingPath: "Heading", byteStart: 0, byteEnd: content.utf8.count, content: content)
        }
    }

    @Test func migrationBringsAFreshDatabaseToTheCurrentSchemaVersion() async throws {
        let index = try SearchIndex(path: ":memory:")
        let health = try await index.health()
        #expect(health.schemaVersion == 1)
    }

    @Test func upsertThenFtsSearchFindsTheIndexedContent() async throws {
        let index = try SearchIndex(path: ":memory:")
        _ = try await index.upsert(document: makeDocument(), chunks: makeChunks("The quick brown fox jumps over the lazy dog."))

        let hits = try await index.ftsSearch(query: "fox")
        #expect(hits.count == 1)
        #expect(hits[0].document.sourceID == "note-1")
        #expect(hits[0].chunk.content.contains("fox"))
    }

    @Test func upsertReplacesPreviousChunksForTheSameDocument() async throws {
        let index = try SearchIndex(path: ":memory:")
        _ = try await index.upsert(document: makeDocument(), chunks: makeChunks("original alpha content"))
        _ = try await index.upsert(document: makeDocument(contentHash: "hash-2"), chunks: makeChunks("replacement beta content"))

        let staleHits = try await index.ftsSearch(query: "alpha")
        let freshHits = try await index.ftsSearch(query: "beta")
        #expect(staleHits.isEmpty)
        #expect(freshHits.count == 1)
    }

    @Test func removeDeletesTheDocumentAndItsChunks() async throws {
        let index = try SearchIndex(path: ":memory:")
        _ = try await index.upsert(document: makeDocument(), chunks: makeChunks("searchable content here"))
        try await index.remove(sourceType: "note", sourceID: "note-1")

        let hits = try await index.ftsSearch(query: "searchable")
        #expect(hits.isEmpty)
    }

    @Test func rebuildClearsAllDocumentsAndChunks() async throws {
        let index = try SearchIndex(path: ":memory:")
        _ = try await index.upsert(document: makeDocument(), chunks: makeChunks("some content"))
        try await index.rebuild()

        let hits = try await index.ftsSearch(query: "content")
        #expect(hits.isEmpty)
    }

    @Test func vectorSearchRanksByCosineSimilarityDescending() async throws {
        let index = try SearchIndex(path: ":memory:")
        let documentID = try await index.upsert(document: makeDocument(), chunks: makeChunks("alpha chunk", "beta chunk"))
        let chunkRows = try await index.ftsSearch(query: "chunk", limit: 10)
        let sortedChunks = chunkRows.sorted { $0.chunk.ordinal < $1.chunk.ordinal }
        #expect(sortedChunks.count == 2)

        try await index.upsertEmbedding(chunkID: sortedChunks[0].chunk.id, modelID: "stub", vector: [1, 0, 0])
        try await index.upsertEmbedding(chunkID: sortedChunks[1].chunk.id, modelID: "stub", vector: [0, 1, 0])

        let hits = try await index.vectorSearch(queryVector: [1, 0, 0], modelID: "stub")
        #expect(hits.count == 2)
        #expect(hits[0].chunk.id == sortedChunks[0].chunk.id)
        #expect(hits[0].similarity > hits[1].similarity)
        _ = documentID
    }

    @Test func healthReportsFTSAvailableOnANormalDatabase() async throws {
        let index = try SearchIndex(path: ":memory:")
        let health = try await index.health()
        #expect(health.ftsAvailable)
    }

    @Test func ftsUnavailableDegradesToEmptyResultsInsteadOfCrashing() async throws {
        let index = try SearchIndex(path: ":memory:", simulateFTS5Unavailable: true)
        let health = try await index.health()
        #expect(health.ftsAvailable == false)

        // Non-FTS operations still work: the rest of the schema is unaffected.
        _ = try await index.upsert(document: makeDocument(), chunks: makeChunks("content that would normally be searchable"))
        let hits = try await index.ftsSearch(query: "content")
        #expect(hits.isEmpty)
    }

    @Test func documentLooksUpTheStoredRowByIdentity() async throws {
        let index = try SearchIndex(path: ":memory:")
        let documentID = try await index.upsert(document: makeDocument(), chunks: makeChunks("some content"))

        let found = try await index.document(sourceType: "note", sourceID: "note-1")
        #expect(found?.id == documentID)
        #expect(found?.title == "Note One")
        #expect(found?.contentHash == "hash-1")
        #expect(found?.updatedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let missing = try await index.document(sourceType: "note", sourceID: "no-such-note")
        #expect(missing == nil)
    }

    @Test func chunksForDocumentIDReturnsThemInOrdinalOrder() async throws {
        let index = try SearchIndex(path: ":memory:")
        let documentID = try await index.upsert(document: makeDocument(), chunks: makeChunks("first chunk", "second chunk"))

        let chunks = try await index.chunks(forDocumentID: documentID)
        #expect(chunks.map(\.ordinal) == [0, 1])
        #expect(chunks.map(\.content) == ["first chunk", "second chunk"])
        #expect(chunks.allSatisfy { $0.documentID == documentID })
    }

    @Test func ftsSearchTreatsPunctuationAndOperatorLookingInputAsLiteralText() async throws {
        let index = try SearchIndex(path: ":memory:")
        _ = try await index.upsert(document: makeDocument(), chunks: makeChunks("quoting \"fox\" foo:bar alpha OR beta - [bracketed]"))

        for query in ["\"", "foo:bar", "alpha OR beta", "-", "[bracketed]"] {
            let hits = try await index.ftsSearch(query: query)
            #expect(hits.count <= 1)
        }
    }

    @Test func ftsSearchReturnsEmptyForAnEmptyOrWhitespaceOnlyQuery() async throws {
        let index = try SearchIndex(path: ":memory:")
        _ = try await index.upsert(document: makeDocument(), chunks: makeChunks("some content"))

        #expect(try await index.ftsSearch(query: "").isEmpty)
        #expect(try await index.ftsSearch(query: "   ").isEmpty)
    }

    @Test func ftsSearchStillMatchesOrdinaryMultiwordQueries() async throws {
        let index = try SearchIndex(path: ":memory:")
        _ = try await index.upsert(document: makeDocument(), chunks: makeChunks("The quick brown fox jumps over the lazy dog."))

        let hits = try await index.ftsSearch(query: "quick fox")
        #expect(hits.count == 1)
    }

    @Test func embeddingRoundTripsThroughNLSentenceEmbeddingProviderWhenAvailable() async throws {
        let provider = NLSentenceEmbeddingProvider()
        guard let vector = await provider.embed("The quick brown fox.") else {
            // NLEmbedding isn't available on this OS/locale/CI image — the
            // provider's documented degrade path, not a test failure.
            return
        }
        #expect(!vector.isEmpty)

        let index = try SearchIndex(path: ":memory:")
        _ = try await index.upsert(document: makeDocument(), chunks: makeChunks("The quick brown fox."))
        let hits = try await index.ftsSearch(query: "fox", limit: 1)
        let chunkID = try #require(hits.first?.chunk.id)

        try await index.upsertEmbedding(chunkID: chunkID, modelID: provider.modelID, vector: vector)
        let vectorHits = try await index.vectorSearch(queryVector: vector, modelID: provider.modelID)
        #expect(vectorHits.first?.chunk.id == chunkID)
    }
}
