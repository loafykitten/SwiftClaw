import Foundation
// NLEmbedding isn't marked `Sendable` upstream, though Apple documents its
// vector-lookup API as safe to call concurrently once loaded; `@preconcurrency`
// downgrades that specific mismatch to a warning instead of routing around it
// with an `@unchecked Sendable` wrapper of our own.
@preconcurrency import NaturalLanguage

/// Seam between the search engine and whatever produces chunk embeddings.
/// `SearchIndex` stores `model_id` + `dim` alongside every embedding, so
/// swapping the provider (a remote model, `NLContextualEmbedding`, …) later
/// never requires a migration — old rows just carry a different model_id.
/// Embedding work is deliberately nonisolated: indexing can process many
/// chunks, and running each vector lookup on the app's default main actor
/// would make a rebuild freeze the UI.
nonisolated protocol TextEmbeddingProvider: Sendable {
    /// Identifies the embedding space rows came from — stored per-embedding
    /// so mixed-model rows in the same index never get compared to each other.
    var modelID: String { get }

    /// `nil` when the provider can't currently produce an embedding (model
    /// unavailable, unsupported language, empty input) — callers degrade to
    /// FTS-only search rather than treating this as an error.
    func embed(_ text: String) async -> [Float]?
}

/// Wraps `NLEmbedding.sentenceEmbedding(for:)` — on-device, no network.
/// Degrades to `nil` (FTS-only search) when the model isn't available for
/// `language` on the current OS/locale.
nonisolated struct NLSentenceEmbeddingProvider: TextEmbeddingProvider {
    let modelID: String
    private let embedding: NLEmbedding?

    init(language: NLLanguage = .english) {
        modelID = "nlembedding.sentence.\(language.rawValue)"
        embedding = NLEmbedding.sentenceEmbedding(for: language)
    }

    func embed(_ text: String) async -> [Float]? {
        guard let embedding, !text.isEmpty, let vector = embedding.vector(for: text) else { return nil }
        return vector.map(Float.init)
    }
}
