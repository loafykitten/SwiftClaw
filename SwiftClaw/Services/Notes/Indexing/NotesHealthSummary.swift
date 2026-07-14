import Foundation

/// A snapshot of vault health for settings/banner UI. Produced by
/// `NotesIndexer.healthSummary()`, which queries the live index/link graph
/// rather than caching any of this — a stale "healthy" reading would defeat
/// the point of a health surface.
struct NotesHealthSummary: Sendable, Equatable {
    let brokenLinkCount: Int
    let conflictCopyCount: Int
    let ftsAvailable: Bool
    let embeddingAvailable: Bool
    let lastIndexSuccessAt: Date?
    /// Paths that failed during the last `apply(delta:)`/`rebuildAll()` run —
    /// surfaced plainly rather than folded into a boolean.
    let lastIndexFailedPaths: [String]
    /// A plain description of any error hit while assembling this summary
    /// itself (e.g. the index database became unreadable) — never silently
    /// converted into a healthy-looking reading.
    let indexError: String?

    /// Fixed probe text for checking whether the configured embedding
    /// provider currently produces vectors (vs. e.g. an `NLEmbedding` model
    /// missing for the running OS/locale) — a stable, deterministic input,
    /// not the vault's own content.
    static let embeddingProbeText = "SwiftClaw notes embedding availability probe"

    /// Matches `NotesVault`'s conflict-copy naming convention exactly:
    /// `"Name (conflict yyyy-MM-dd HHmmss[ n]).md"`.
    nonisolated static func isConflictCopy(_ relativePath: String) -> Bool {
        relativePath.range(of: #"\(conflict \d{4}-\d{2}-\d{2} \d{6}( \d+)?\)\.md$"#, options: .regularExpression) != nil
    }
}
