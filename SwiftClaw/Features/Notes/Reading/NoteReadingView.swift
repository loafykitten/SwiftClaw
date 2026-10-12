import SwiftUI

/// Reading mode for a note's currently persisted content. Wikilink taps
/// navigate to the note the link graph's resolution policy picks from the
/// current catalog (exact path first, then a unique stem; ambiguous links
/// open nothing).
/// Relative image references (`![alt](path)` and `![[embed]]`) are loaded
/// only through `NotesRepository.readData(relativePath:)`, resolved first
/// relative to the note's own folder — the standard Markdown interpretation
/// — and only then relative to the vault root, for notes that already rely
/// on root-relative image paths. Both candidates are normalized lexically
/// (collapsing `.`/`..` segments) before ever reaching the repository, and
/// any path that would escape above the vault root is rejected outright —
/// never through direct file access.
struct NoteReadingView: View {
    let content: String
    let notePath: String
    let model: NotesFeatureModel

    var body: some View {
        ScrollView {
            MarkdownRenderedView(
                source: content,
                imageLoadScope: notePath,
                onWikilinkTap: { target in
                    guard let path = Self.matchingNotePath(forTarget: target, from: notePath, in: model.notes),
                          path != notePath else { return }
                    Task { await model.select(path: path) }
                },
                loadImage: { relativePath in
                    await Self.loadImage(relativePath: relativePath, notePath: notePath, model: model)
                }
            )
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Note content, reading mode")
    }

    /// The same resolution policy as backlinks and broken-link health
    /// (`NoteLinkGraph.resolve`): an exact path match beats any stem match,
    /// and an ambiguous target opens nothing rather than an arbitrary note.
    static func matchingNotePath(forTarget target: String, from notePath: String, in notes: [NoteSummary]) -> String? {
        NoteLinkGraph.resolve(target: target, sourcePath: notePath, among: notes.map(\.relativePath))
    }

    private static func loadImage(relativePath: String, notePath: String, model: NotesFeatureModel) async -> PlatformImage? {
        guard let repository = model.repository else { return nil }
        for candidate in candidatePaths(for: relativePath, notePath: notePath) {
            if let data = try? await repository.readData(relativePath: candidate), let image = PlatformImage(data: data) {
                return image
            }
        }
        return nil
    }

    /// Note-directory-relative resolution first (standard Markdown image
    /// semantics), then vault-root-relative as a fallback for notes that
    /// already rely on it. Both candidates are lexically normalized and
    /// filtered through `normalizedRelativePath`, so a path that resolves
    /// outside the vault root is dropped rather than ever reaching the
    /// repository.
    static func candidatePaths(for relativePath: String, notePath: String) -> [String] {
        let noteFolder = (notePath as NSString).deletingLastPathComponent
        var candidates: [String] = []
        if let noteRelative = normalizedRelativePath(basePath: noteFolder, relativePath: relativePath) {
            candidates.append(noteRelative)
        }
        if let rootRelative = normalizedRelativePath(basePath: "", relativePath: relativePath),
           !candidates.contains(rootRelative) {
            candidates.append(rootRelative)
        }
        return candidates
    }

    /// Joins `relativePath` onto `basePath` and resolves the result lexically
    /// — `.` segments are dropped and `..` segments pop the preceding
    /// component — without ever touching the filesystem. Returns `nil` for
    /// an absolute `relativePath` or one that would climb above `basePath`'s
    /// root (a `..` with nothing left to pop), so an escaping reference is
    /// rejected before it can reach `NotesRepository.readData(relativePath:)`.
    static func normalizedRelativePath(basePath: String, relativePath: String) -> String? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        var components = basePath.split(separator: "/").map(String.init)
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}
