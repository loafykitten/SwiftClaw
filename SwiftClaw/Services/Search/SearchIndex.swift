import Foundation

/// Source-agnostic full-text + vector index. Callers identify content with
/// `sourceType`/`sourceID` (Notes is the first adapter; email/chat indexing
/// is a later, migration-free addition per `docs/features/NOTES.md`
/// cross-feature follow-up #2) — this type
/// imports nothing feature-specific.
///
/// An **actor** over a single `SQLiteDatabase` connection; schema
/// application is idempotent and lazy (`ensureSchema()` runs once per
/// instance, on first use).
actor SearchIndex {
    enum IndexError: LocalizedError, Equatable {
        case documentLookupFailed
        case malformedRow
        case invalidEmbedding(String)

        var errorDescription: String? {
            switch self {
            case .documentLookupFailed: "Couldn't look up the document just written to the search index."
            case .malformedRow: "The search index returned a row in an unexpected shape."
            case .invalidEmbedding(let reason): "Invalid embedding: \(reason)"
            }
        }
    }

    struct Document: Sendable, Equatable {
        let id: Int64
        let sourceType: String
        let sourceID: String
        let title: String
        let uri: String
        let contentHash: String
        let updatedAt: Date
    }

    struct Chunk: Sendable, Equatable {
        let id: Int64
        let documentID: Int64
        let ordinal: Int
        let headingPath: String
        let byteStart: Int
        let byteEnd: Int
        let content: String
    }

    /// A document as the caller sees it, before the index has assigned an id.
    struct DocumentInput: Sendable, Equatable {
        let sourceType: String
        let sourceID: String
        let title: String
        let uri: String
        let contentHash: String
        let updatedAt: Date

        init(sourceType: String, sourceID: String, title: String, uri: String, contentHash: String, updatedAt: Date) {
            self.sourceType = sourceType
            self.sourceID = sourceID
            self.title = title
            self.uri = uri
            self.contentHash = contentHash
            self.updatedAt = updatedAt
        }
    }

    struct ChunkInput: Sendable, Equatable {
        let ordinal: Int
        let headingPath: String
        let byteStart: Int
        let byteEnd: Int
        let content: String

        init(ordinal: Int, headingPath: String, byteStart: Int, byteEnd: Int, content: String) {
            self.ordinal = ordinal
            self.headingPath = headingPath
            self.byteStart = byteStart
            self.byteEnd = byteEnd
            self.content = content
        }
    }

    struct FTSHit: Sendable, Equatable {
        let document: Document
        let chunk: Chunk
        let rank: Double
        let snippet: String?

        init(document: Document, chunk: Chunk, rank: Double, snippet: String? = nil) {
            self.document = document
            self.chunk = chunk
            self.rank = rank
            self.snippet = snippet
        }
    }

    struct VectorHit: Sendable, Equatable {
        let document: Document
        let chunk: Chunk
        let similarity: Double
    }

    struct Health: Sendable, Equatable {
        let schemaVersion: Int32
        let ftsAvailable: Bool
    }

    private static let schemaVersion: Int32 = 1

    /// Apple English sentence embeddings measured 0.613 for a direct
    /// paraphrase and about 0.16 for unrelated sentences in local calibration.
    /// A 0.50 floor keeps the strong paraphrase while removing the far tail.
    static let defaultMinimumCosineSimilarity = 0.50

    private let database: SQLiteDatabase
    /// Test-only seam: production callers never set this. Real FTS5
    /// availability is always probed against the live SQLite build; this
    /// lets tests exercise the "unavailable" health path deterministically
    /// without depending on how the OS's SQLite happens to be compiled.
    private let simulateFTS5Unavailable: Bool
    private var schemaReady = false
    private var ftsAvailable = false

    init(path: String, simulateFTS5Unavailable: Bool = false) throws {
        database = try SQLiteDatabase(path: path)
        self.simulateFTS5Unavailable = simulateFTS5Unavailable
    }

    /// Inserts or replaces the document identified by
    /// `(sourceType, sourceID)` and its chunks (existing chunks for that
    /// document — and their embeddings/FTS rows, via `ON DELETE CASCADE`
    /// and the sync triggers — are dropped and replaced). Returns the
    /// document's row id.
    @discardableResult
    func upsert(document: DocumentInput, chunks: [ChunkInput]) async throws -> Int64 {
        try await ensureSchema()
        try await database.execute("BEGIN;")
        do {
            try await database.execute(
                """
                INSERT INTO documents (source_type, source_id, title, uri, content_hash, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_type, source_id) DO UPDATE SET
                    title = excluded.title,
                    uri = excluded.uri,
                    content_hash = excluded.content_hash,
                    updated_at = excluded.updated_at;
                """,
                params: [
                    .text(document.sourceType), .text(document.sourceID), .text(document.title),
                    .text(document.uri), .text(document.contentHash), .real(document.updatedAt.timeIntervalSince1970),
                ]
            )
            let rows = try await database.query(
                "SELECT id FROM documents WHERE source_type = ? AND source_id = ?;",
                params: [.text(document.sourceType), .text(document.sourceID)]
            )
            guard case .integer(let documentID)? = rows.first?.first else {
                throw IndexError.documentLookupFailed
            }
            try await database.execute("DELETE FROM chunks WHERE document_id = ?;", params: [.integer(documentID)])
            for chunk in chunks {
                try await database.execute(
                    """
                    INSERT INTO chunks (document_id, ordinal, heading_path, byte_start, byte_end, content)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """,
                    params: [
                        .integer(documentID), .integer(Int64(chunk.ordinal)), .text(chunk.headingPath),
                        .integer(Int64(chunk.byteStart)), .integer(Int64(chunk.byteEnd)), .text(chunk.content),
                    ]
                )
            }
            try await database.execute("COMMIT;")
            return documentID
        } catch {
            try? await database.execute("ROLLBACK;")
            throw error
        }
    }

    /// Removes a document and (via cascade) its chunks and embeddings.
    /// A no-op if the document doesn't exist.
    func remove(sourceType: String, sourceID: String) async throws {
        try await ensureSchema()
        try await database.execute(
            "DELETE FROM documents WHERE source_type = ? AND source_id = ?;",
            params: [.text(sourceType), .text(sourceID)]
        )
    }

    /// Replaces a chunk's embedding for `modelID` (one embedding per
    /// chunk+model). `vector.count` becomes the stored `dim`.
    func upsertEmbedding(chunkID: Int64, modelID: String, vector: [Float]) async throws {
        try await ensureSchema()
        guard !vector.isEmpty else {
            throw IndexError.invalidEmbedding("vector must not be empty")
        }
        try await database.execute(
            """
            INSERT INTO embeddings (chunk_id, model_id, dim, vector)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(chunk_id, model_id) DO UPDATE SET
                dim = excluded.dim,
                vector = excluded.vector;
            """,
            params: [
                .integer(chunkID), .text(modelID), .integer(Int64(vector.count)), .blob(Self.encode(vector)),
            ]
        )
    }

    /// Full-text search over chunk content, best match first. Returns an
    /// empty array (rather than throwing) when FTS5 is unavailable.
    func ftsSearch(query: String, limit: Int = 20) async throws -> [FTSHit] {
        try await ensureSchema()
        guard ftsAvailable else { return [] }
        guard let matchQuery = Self.literalMatchQuery(for: query) else { return [] }
        let rows = try await database.query(
            """
            SELECT c.id, c.document_id, c.ordinal, c.heading_path, c.byte_start, c.byte_end, c.content,
                   d.id, d.source_type, d.source_id, d.title, d.uri, d.content_hash, d.updated_at,
                   snippet(chunks_fts, -1, '', '', '…', 32) AS snippet,
                   bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.id = chunks_fts.rowid
            JOIN documents d ON d.id = c.document_id
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?;
            """,
            params: [.text(matchQuery), .integer(Int64(limit))]
        )
        return try rows.map(Self.decodeFTSHit)
    }

    /// Brute-force cosine-similarity search over embeddings for `modelID`,
    /// best match first. Rows whose stored `dim` doesn't match
    /// `queryVector.count` are skipped rather than treated as an error, so a
    /// stale embedding from a retired model can't crash a search.
    func vectorSearch(
        queryVector: [Float],
        modelID: String,
        limit: Int = 20,
        minimumSimilarity: Double = defaultMinimumCosineSimilarity
    ) async throws -> [VectorHit] {
        try await ensureSchema()
        guard !queryVector.isEmpty else { return [] }
        let rows = try await database.query(
            """
            SELECT e.dim, e.vector,
                   c.id, c.document_id, c.ordinal, c.heading_path, c.byte_start, c.byte_end, c.content,
                   d.id, d.source_type, d.source_id, d.title, d.uri, d.content_hash, d.updated_at
            FROM embeddings e
            JOIN chunks c ON c.id = e.chunk_id
            JOIN documents d ON d.id = c.document_id
            WHERE e.model_id = ?;
            """,
            params: [.text(modelID)]
        )
        var scored: [(hit: VectorHit, similarity: Double)] = []
        for row in rows {
            guard let scoredHit = try Self.decodeVectorHit(row, queryVector: queryVector) else { continue }
            guard scoredHit.similarity >= minimumSimilarity else { continue }
            scored.append((scoredHit, scoredHit.similarity))
        }
        scored.sort { lhs, rhs in
            lhs.similarity != rhs.similarity ? lhs.similarity > rhs.similarity : lhs.hit.chunk.id < rhs.hit.chunk.id
        }
        return scored.prefix(limit).map(\.hit)
    }

    /// Wipes all documents/chunks/embeddings (and, via triggers, FTS rows)
    /// back to empty. The index is a rebuildable cache — callers re-run
    /// their own upserts afterward.
    func rebuild() async throws {
        try await ensureSchema()
        try await database.execute("DELETE FROM documents;")
    }

    func health() async throws -> Health {
        try await ensureSchema()
        return Health(schemaVersion: Self.schemaVersion, ftsAvailable: ftsAvailable)
    }

    /// Looks up the document currently indexed for `(sourceType, sourceID)`,
    /// if any. Callers use this to short-circuit re-chunking/re-embedding an
    /// unchanged source: compare `contentHash` against a freshly computed
    /// hash before doing any parsing work.
    func document(sourceType: String, sourceID: String) async throws -> Document? {
        try await ensureSchema()
        let rows = try await database.query(
            "SELECT id, source_type, source_id, title, uri, content_hash, updated_at FROM documents WHERE source_type = ? AND source_id = ?;",
            params: [.text(sourceType), .text(sourceID)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decodeDocument(row)
    }

    /// All chunks belonging to `documentID`, ordinal ascending. `upsert` only
    /// returns the document's row id, not the ids it assigned the chunks —
    /// callers that need those (e.g. to attach embeddings) look them up here.
    func chunks(forDocumentID documentID: Int64) async throws -> [Chunk] {
        try await ensureSchema()
        let rows = try await database.query(
            "SELECT id, document_id, ordinal, heading_path, byte_start, byte_end, content FROM chunks WHERE document_id = ? ORDER BY ordinal;",
            params: [.integer(documentID)]
        )
        return try rows.map(Self.decodeChunk)
    }

    // MARK: - Schema

    private func ensureSchema() async throws {
        guard !schemaReady else { return }
        let version = try await database.currentUserVersion()
        if version < Self.schemaVersion {
            try await applyV1Schema()
            try await database.setUserVersion(Self.schemaVersion)
        } else {
            ftsAvailable = await attemptCreateFTS()
        }
        schemaReady = true
    }

    private func applyV1Schema() async throws {
        try await database.execute(
            """
            CREATE TABLE IF NOT EXISTS documents (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_type TEXT NOT NULL,
                source_id TEXT NOT NULL,
                title TEXT NOT NULL,
                uri TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE(source_type, source_id)
            );
            """
        )
        try await database.execute(
            """
            CREATE TABLE IF NOT EXISTS chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                heading_path TEXT NOT NULL,
                byte_start INTEGER NOT NULL,
                byte_end INTEGER NOT NULL,
                content TEXT NOT NULL
            );
            """
        )
        try await database.execute("CREATE INDEX IF NOT EXISTS idx_chunks_document_id ON chunks(document_id);")
        try await database.execute(
            """
            CREATE TABLE IF NOT EXISTS embeddings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chunk_id INTEGER NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
                model_id TEXT NOT NULL,
                dim INTEGER NOT NULL,
                vector BLOB NOT NULL,
                UNIQUE(chunk_id, model_id)
            );
            """
        )
        ftsAvailable = await attemptCreateFTS()
    }

    /// External-content FTS5 over `chunks.content`. External-content tables
    /// don't auto-sync, so triggers mirror every insert/update/delete.
    /// Returns `false` (never throws) so missing FTS5 support becomes a
    /// health flag rather than a failed migration.
    private func attemptCreateFTS() async -> Bool {
        guard !simulateFTS5Unavailable else { return false }
        do {
            try await database.execute(
                """
                CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                    content,
                    content='chunks',
                    content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                );
                """
            )
            try await database.execute(
                """
                CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
                    INSERT INTO chunks_fts(rowid, content) VALUES (new.id, new.content);
                END;
                """
            )
            try await database.execute(
                """
                CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
                    INSERT INTO chunks_fts(chunks_fts, rowid, content) VALUES ('delete', old.id, old.content);
                END;
                """
            )
            try await database.execute(
                """
                CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
                    INSERT INTO chunks_fts(chunks_fts, rowid, content) VALUES ('delete', old.id, old.content);
                    INSERT INTO chunks_fts(rowid, content) VALUES (new.id, new.content);
                END;
                """
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - FTS query sanitization

    /// Turns arbitrary user-entered search text into a literal FTS5 MATCH
    /// query: every whitespace-separated token is wrapped as an FTS5 string
    /// literal (embedded `"` doubled per the FTS5 grammar), so punctuation
    /// like `foo:bar`, `OR`, `-`, or a stray `"` can never be parsed as query
    /// syntax. Tokens are left space-separated (FTS5's implicit `AND`), which
    /// keeps ordinary multiword input matching each word rather than only an
    /// exact phrase. Returns `nil` for an empty or all-whitespace query.
    private static func literalMatchQuery(for query: String) -> String? {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }
        return tokens
            .map { "\"\(String($0).replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
    }

    // MARK: - Row decoding

    /// Matches `document(sourceType:sourceID:)`'s
    /// `SELECT id, source_type, source_id, title, uri, content_hash, updated_at`.
    private static func decodeDocument(_ row: [SQLiteValue]) throws -> Document {
        guard row.count == 7,
              let id = int64(row[0]), let sourceType = string(row[1]), let sourceID = string(row[2]),
              let title = string(row[3]), let uri = string(row[4]), let contentHash = string(row[5]),
              let updatedAt = double(row[6])
        else {
            throw IndexError.malformedRow
        }
        return Document(
            id: id, sourceType: sourceType, sourceID: sourceID, title: title, uri: uri,
            contentHash: contentHash, updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    /// Matches `chunks(forDocumentID:)`'s
    /// `SELECT id, document_id, ordinal, heading_path, byte_start, byte_end, content`.
    private static func decodeChunk(_ row: [SQLiteValue]) throws -> Chunk {
        guard row.count == 7,
              let id = int64(row[0]), let documentID = int64(row[1]), let ordinal = int64(row[2]),
              let headingPath = string(row[3]), let byteStart = int64(row[4]), let byteEnd = int64(row[5]),
              let content = string(row[6])
        else {
            throw IndexError.malformedRow
        }
        return Chunk(
            id: id, documentID: documentID, ordinal: Int(ordinal), headingPath: headingPath,
            byteStart: Int(byteStart), byteEnd: Int(byteEnd), content: content
        )
    }

    private static func decodeFTSHit(_ row: [SQLiteValue]) throws -> FTSHit {
        guard row.count == 16,
              let chunkID = int64(row[0]), let documentID = int64(row[1]), let ordinal = int64(row[2]),
              let headingPath = string(row[3]), let byteStart = int64(row[4]), let byteEnd = int64(row[5]),
              let content = string(row[6]), let docID = int64(row[7]), let sourceType = string(row[8]),
              let sourceID = string(row[9]), let title = string(row[10]), let uri = string(row[11]),
              let contentHash = string(row[12]), let updatedAt = double(row[13]), let snippet = string(row[14]),
              let rank = double(row[15])
        else {
            throw IndexError.malformedRow
        }
        let chunk = Chunk(
            id: chunkID, documentID: documentID, ordinal: Int(ordinal), headingPath: headingPath,
            byteStart: Int(byteStart), byteEnd: Int(byteEnd), content: content
        )
        let document = Document(
            id: docID, sourceType: sourceType, sourceID: sourceID, title: title, uri: uri,
            contentHash: contentHash, updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
        return FTSHit(document: document, chunk: chunk, rank: rank, snippet: snippet)
    }

    private static func decodeVectorHit(_ row: [SQLiteValue], queryVector: [Float]) throws -> VectorHit? {
        guard row.count == 16,
              let dim = int64(row[0]), let vectorBlob = blob(row[1]),
              let chunkID = int64(row[2]), let documentID = int64(row[3]), let ordinal = int64(row[4]),
              let headingPath = string(row[5]), let byteStart = int64(row[6]), let byteEnd = int64(row[7]),
              let content = string(row[8]), let docID = int64(row[9]), let sourceType = string(row[10]),
              let sourceID = string(row[11]), let title = string(row[12]), let uri = string(row[13]),
              let contentHash = string(row[14]), let updatedAt = double(row[15])
        else {
            throw IndexError.malformedRow
        }
        guard Int(dim) == queryVector.count else { return nil }
        let vector = decode(vectorBlob)
        guard vector.count == queryVector.count else { return nil }
        let chunk = Chunk(
            id: chunkID, documentID: documentID, ordinal: Int(ordinal), headingPath: headingPath,
            byteStart: Int(byteStart), byteEnd: Int(byteEnd), content: content
        )
        let document = Document(
            id: docID, sourceType: sourceType, sourceID: sourceID, title: title, uri: uri,
            contentHash: contentHash, updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
        return VectorHit(document: document, chunk: chunk, similarity: cosineSimilarity(queryVector, vector))
    }

    private static func int64(_ value: SQLiteValue) -> Int64? {
        if case .integer(let intValue) = value { return intValue }
        return nil
    }

    private static func string(_ value: SQLiteValue) -> String? {
        if case .text(let stringValue) = value { return stringValue }
        return nil
    }

    private static func double(_ value: SQLiteValue) -> Double? {
        switch value {
        case .real(let doubleValue): doubleValue
        case .integer(let intValue): Double(intValue)
        default: nil
        }
    }

    private static func blob(_ value: SQLiteValue) -> Data? {
        if case .blob(let data) = value { return data }
        return nil
    }

    // MARK: - Vector encoding

    /// Raw `Float32` bytes, machine-native order. Local-only cache, not
    /// meant to be portable across machines/architectures.
    private static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decode(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Double = 0
        var lhsMagnitude: Double = 0
        var rhsMagnitude: Double = 0
        for index in lhs.indices {
            let lhsValue = Double(lhs[index])
            let rhsValue = Double(rhs[index])
            dot += lhsValue * rhsValue
            lhsMagnitude += lhsValue * lhsValue
            rhsMagnitude += rhsValue * rhsValue
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (lhsMagnitude.squareRoot() * rhsMagnitude.squareRoot())
    }
}
