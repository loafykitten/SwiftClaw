import Foundation

/// One search result: a chunk plus enough of its parent document to render
/// and cite it.
struct SearchHit: Sendable, Equatable {
    let document: SearchIndex.Document
    let chunk: SearchIndex.Chunk
    let headingPath: String
    let snippet: String
    let score: Double
}

/// Combines an FTS ranking and a vector-similarity ranking into one ordered
/// result list via reciprocal rank fusion (`Σ 1/(60 + rank)` per list, ranks
/// 1-based). `fuse` is a pure static function over already-ranked hit
/// arrays — the RRF math is testable with hand-built stub hits, no SQLite
/// or embedding model involved.
struct HybridSearcher: Sendable {
    private static let rrfConstant = 60.0
    static let defaultSnippetLength = 220

    let searchIndex: SearchIndex
    let embeddingProvider: TextEmbeddingProvider?

    init(searchIndex: SearchIndex, embeddingProvider: TextEmbeddingProvider? = nil) {
        self.searchIndex = searchIndex
        self.embeddingProvider = embeddingProvider
    }

    /// Runs FTS (and, if an embedding provider is configured and produces a
    /// vector, vector) search and fuses the two rankings. Either retrieval
    /// path degrading to empty (FTS5 unavailable, embedding unavailable)
    /// still returns results from whichever path succeeded.
    func search(query: String, limit: Int = 20) async throws -> [SearchHit] {
        let ftsHits = try await searchIndex.ftsSearch(query: query, limit: limit)
        var vectorHits: [SearchIndex.VectorHit] = []
        if let embeddingProvider, let queryVector = await embeddingProvider.embed(query) {
            vectorHits = try await searchIndex.vectorSearch(
                queryVector: queryVector, modelID: embeddingProvider.modelID, limit: limit
            )
        }
        return Self.fuse(ftsHits: ftsHits, vectorHits: vectorHits, limit: limit)
    }

    /// Pure RRF fusion. Ties are broken by chunk id, ascending, so the
    /// result order is fully deterministic for a given pair of inputs.
    static func fuse(ftsHits: [SearchIndex.FTSHit], vectorHits: [SearchIndex.VectorHit], limit: Int = 20) -> [SearchHit] {
        var scores: [Int64: Double] = [:]
        var lookup: [Int64: (document: SearchIndex.Document, chunk: SearchIndex.Chunk, ftsSnippet: String?)] = [:]

        for (offset, hit) in ftsHits.enumerated() {
            scores[hit.chunk.id, default: 0] += 1.0 / (rrfConstant + Double(offset + 1))
            lookup[hit.chunk.id] = (hit.document, hit.chunk, hit.snippet)
        }
        for (offset, hit) in vectorHits.enumerated() {
            scores[hit.chunk.id, default: 0] += 1.0 / (rrfConstant + Double(offset + 1))
            lookup[hit.chunk.id] = (hit.document, hit.chunk, lookup[hit.chunk.id]?.ftsSnippet)
        }

        let ranked = scores.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        return ranked.prefix(limit).compactMap { chunkID, score in
            guard let entry = lookup[chunkID] else { return nil }
            return SearchHit(
                document: entry.document,
                chunk: entry.chunk,
                headingPath: entry.chunk.headingPath,
                snippet: collapsedToSingleLine(entry.ftsSnippet ?? snippet(from: entry.chunk.content)),
                score: score
            )
        }
    }

    static func snippet(from content: String, maxLength: Int = defaultSnippetLength) -> String {
        var inFrontMatter = false
        var sawFirstLine = false
        let fallbackLine = content.split(separator: "\n", omittingEmptySubsequences: false).first { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { sawFirstLine = true }

            if !sawFirstLine, trimmed == "---" {
                inFrontMatter = true
                return false
            }
            if inFrontMatter {
                if trimmed == "---" {
                    inFrontMatter = false
                }
                return false
            }
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }.map { String($0).trimmingCharacters(in: .whitespaces) } ?? content

        guard fallbackLine.count > maxLength else { return fallbackLine }
        let endIndex = fallbackLine.index(fallbackLine.startIndex, offsetBy: maxLength)
        return String(fallbackLine[..<endIndex]) + "…"
    }

    /// A multi-line FTS window can spend a result row's entire line budget on
    /// list markers or headings before reaching the match, so snippets are
    /// flattened for display (also keeps `search_notes` citations compact).
    static func collapsedToSingleLine(_ snippet: String) -> String {
        snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
