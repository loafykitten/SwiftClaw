import Testing
@testable import SwiftClaw

/// Regression coverage for the review finding that `NoteReadingView` tried
/// vault-root-relative resolution *before* the note's own directory (backward
/// from standard Markdown image semantics) and rejected any `.`/`..` segment
/// outright rather than normalizing it lexically. `candidatePaths` and
/// `normalizedRelativePath` are exercised directly rather than through the
/// SwiftUI view tree, per the small-testable-helper preference elsewhere in
/// this suite.
struct NoteReadingViewTests {
    @Test func noteDirectoryResolutionIsTriedBeforeTheSameNamedVaultRootAsset() {
        let candidates = NoteReadingView.candidatePaths(for: "img.png", notePath: "sub/note.md")
        #expect(candidates == ["sub/img.png", "img.png"])
    }

    @Test func dotSegmentsAreNormalizedLexicallyRatherThanRejected() {
        let candidates = NoteReadingView.candidatePaths(for: "./assets/./img.png", notePath: "sub/note.md")
        #expect(candidates == ["sub/assets/img.png", "assets/img.png"])
    }

    @Test func parentTraversalThatStaysWithinTheVaultResolvesRelativeToTheNoteDirectory() {
        let candidates = NoteReadingView.candidatePaths(for: "../sibling/img.png", notePath: "sub/child/note.md")
        #expect(candidates == ["sub/sibling/img.png"])
    }

    @Test func aPathThatWouldEscapeAboveTheVaultRootIsRejectedEntirely() {
        let candidates = NoteReadingView.candidatePaths(for: "../img.png", notePath: "note.md")
        #expect(candidates.isEmpty)
    }

    @Test func normalizedRelativePathRejectsAnAbsolutePath() {
        #expect(NoteReadingView.normalizedRelativePath(basePath: "sub", relativePath: "/etc/passwd") == nil)
    }

    private func notes(_ paths: [String]) -> [NoteSummary] {
        paths.map {
            NoteSummary(relativePath: $0, title: NoteSummary.title(forRelativePath: $0), sha256: "h", modifiedAt: .distantPast)
        }
    }

    /// An exact path match must win even when a same-stem note sorts first.
    @Test func wikilinkTapPrefersTheExactPathOverAnEarlierSameStemNote() {
        let catalog = notes(["A/Topic.md", "Topic.md"])
        #expect(NoteReadingView.matchingNotePath(forTarget: "Topic", from: "Index.md", in: catalog) == "Topic.md")
        #expect(NoteReadingView.matchingNotePath(forTarget: "A/Topic", from: "Index.md", in: catalog) == "A/Topic.md")
        #expect(NoteReadingView.matchingNotePath(forTarget: "Topic#Section", from: "Index.md", in: catalog) == "Topic.md")
    }

    @Test func wikilinkTapResolvesAUniqueStemAndRefusesAnAmbiguousOne() {
        #expect(NoteReadingView.matchingNotePath(forTarget: "topic", from: "Index.md", in: notes(["A/Topic.md"])) == "A/Topic.md")
        #expect(NoteReadingView.matchingNotePath(forTarget: "Topic", from: "Index.md", in: notes(["A/Topic.md", "B/Topic.md"])) == nil)
        #expect(NoteReadingView.matchingNotePath(forTarget: "Missing", from: "Index.md", in: notes(["A/Topic.md"])) == nil)
    }

    @Test func normalizedRelativePathPopsOnlyAsManyComponentsAsTheBaseHas() {
        #expect(NoteReadingView.normalizedRelativePath(basePath: "a/b", relativePath: "../../img.png") == "img.png")
        #expect(NoteReadingView.normalizedRelativePath(basePath: "a/b", relativePath: "../../../img.png") == nil)
    }
}
