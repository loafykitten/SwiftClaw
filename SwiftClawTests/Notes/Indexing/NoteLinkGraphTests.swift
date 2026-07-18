import Foundation
import Testing
@testable import SwiftClaw

@Suite
struct NoteLinkGraphTests {
    private func link(to pagePath: String, kind: WikilinkKind = .link) -> WikilinkOccurrence {
        let normalizedPath = WikilinkScanner.normalize(path: pagePath)
        return WikilinkOccurrence(
            kind: kind, pagePath: pagePath, heading: nil, alias: nil,
            normalizedPath: normalizedPath, normalizedStem: WikilinkScanner.stem(ofNormalizedPath: normalizedPath),
            range: "x".startIndex..<"x".endIndex
        )
    }

    @Test func exactNormalizedPathResolvesEvenWithAmbiguousStemElsewhere() async throws {
        let graph = try NoteLinkGraph(path: ":memory:")
        try await graph.replaceLinksAndTags(forNote: "Folder/Page.md", links: [], tags: [])
        try await graph.replaceLinksAndTags(forNote: "Other/Page.md", links: [], tags: [])
        try await graph.replaceLinksAndTags(forNote: "Source.md", links: [link(to: "Folder/Page")], tags: [])

        let links = try await graph.links(forSource: "Source.md")
        #expect(links.count == 1)
        #expect(links[0].resolvedPath == "Folder/Page.md")
    }

    @Test func uniqueStemResolvesWhenNoExactPathMatchExists() async throws {
        let graph = try NoteLinkGraph(path: ":memory:")
        try await graph.replaceLinksAndTags(forNote: "Deep/Nested/Target.md", links: [], tags: [])
        try await graph.replaceLinksAndTags(forNote: "Source.md", links: [link(to: "Target")], tags: [])

        let links = try await graph.links(forSource: "Source.md")
        #expect(links[0].resolvedPath == "Deep/Nested/Target.md")
    }

    @Test func ambiguousStemWithNoExactMatchStaysUnresolved() async throws {
        let graph = try NoteLinkGraph(path: ":memory:")
        try await graph.replaceLinksAndTags(forNote: "Folder/Duplicate.md", links: [], tags: [])
        try await graph.replaceLinksAndTags(forNote: "Other/Duplicate.md", links: [], tags: [])
        try await graph.replaceLinksAndTags(forNote: "Source.md", links: [link(to: "Duplicate")], tags: [])

        let links = try await graph.links(forSource: "Source.md")
        #expect(links[0].resolvedPath == nil)

        let broken = try await graph.brokenLinks()
        #expect(broken.count == 1)
        #expect(broken[0].pagePath == "Duplicate")
    }

    @Test func ambiguousNormalizedExactPathStaysUnresolved() async throws {
        let graph = try NoteLinkGraph(path: ":memory:")
        try await graph.replaceLinksAndTags(forNote: "Page.md", links: [], tags: [])
        try await graph.replaceLinksAndTags(forNote: "page.md", links: [], tags: [])
        try await graph.replaceLinksAndTags(forNote: "Source.md", links: [link(to: "PAGE")], tags: [])

        #expect(try await graph.links(forSource: "Source.md").first?.resolvedPath == nil)
    }

    @Test func backlinksReturnEveryLinkResolvingToTheTargetNote() async throws {
        let graph = try NoteLinkGraph(path: ":memory:")
        try await graph.replaceLinksAndTags(forNote: "Hub.md", links: [], tags: [])
        try await graph.replaceLinksAndTags(forNote: "A.md", links: [link(to: "Hub")], tags: [])
        try await graph.replaceLinksAndTags(forNote: "B.md", links: [link(to: "Hub")], tags: [])
        try await graph.replaceLinksAndTags(forNote: "C.md", links: [link(to: "SomethingElse")], tags: [])

        let backlinks = try await graph.backlinks(to: "Hub.md")
        #expect(Set(backlinks.map(\.sourcePath)) == ["A.md", "B.md"])
    }

    @Test func replaceLinksAndTagsReplacesPreviousTagsForTheSameNote() async throws {
        let graph = try NoteLinkGraph(path: ":memory:")
        try await graph.replaceLinksAndTags(forNote: "Note.md", links: [], tags: ["project", "swift"])
        #expect(try await graph.tags(forSource: "Note.md").sorted() == ["project", "swift"])

        try await graph.replaceLinksAndTags(forNote: "Note.md", links: [], tags: ["archive"])
        #expect(try await graph.tags(forSource: "Note.md") == ["archive"])
    }

    @Test func removingANoteDropsItsOwnLinksAndTags() async throws {
        let graph = try NoteLinkGraph(path: ":memory:")
        try await graph.replaceLinksAndTags(forNote: "Note.md", links: [link(to: "Target")], tags: ["tag-a"])
        try await graph.removeNote("Note.md")

        #expect(try await graph.links(forSource: "Note.md").isEmpty)
        #expect(try await graph.tags(forSource: "Note.md").isEmpty)
    }

    @Test func removingATargetNoteLeavesExistingBacklinksUnresolvedRatherThanCrashing() async throws {
        let graph = try NoteLinkGraph(path: ":memory:")
        try await graph.replaceLinksAndTags(forNote: "Hub.md", links: [], tags: [])
        try await graph.replaceLinksAndTags(forNote: "A.md", links: [link(to: "Hub")], tags: [])
        try await graph.removeNote("Hub.md")

        let links = try await graph.links(forSource: "A.md")
        #expect(links[0].resolvedPath == nil)
    }

    @Test func rebuildWipesNotesLinksAndTags() async throws {
        let graph = try NoteLinkGraph(path: ":memory:")
        try await graph.replaceLinksAndTags(forNote: "Note.md", links: [link(to: "Target")], tags: ["tag-a"])
        try await graph.rebuild()

        #expect(try await graph.links(forSource: "Note.md").isEmpty)
        #expect(try await graph.tags(forSource: "Note.md").isEmpty)
        #expect(try await graph.brokenLinks().isEmpty)
    }
}
