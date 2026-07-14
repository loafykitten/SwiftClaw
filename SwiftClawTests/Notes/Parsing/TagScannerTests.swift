import Foundation
import Testing
@testable import SwiftClaw

@Suite
struct TagScannerTests {
    @Test func bodyTagIsExtracted() {
        let document = MarkdownDocument(source: "This note is about #swift development.")
        let tags = TagScanner.scan(document)
        #expect(tags.count == 1)
        #expect(tags[0].tag == "swift")
        #expect(tags[0].source == .body)
    }

    @Test func nestedTagKeepsItsFullPath() {
        let document = MarkdownDocument(source: "Filed under #project/swift today.")
        let tags = TagScanner.scan(document)
        #expect(tags.map(\.tag) == ["project/swift"])
    }

    @Test func frontMatterTagsAreIncludedOnce() {
        let document = MarkdownDocument(source: """
        ---
        tags: [swift, notes]
        ---
        Body mentions #swift again.
        """)
        let tags = TagScanner.scan(document)
        let frontMatterTags = tags.filter { $0.source == .frontMatter }.map(\.tag)
        #expect(frontMatterTags.sorted() == ["notes", "swift"])
        // The body occurrence of #swift is still reported separately (it's a
        // real in-body location a UI might want to highlight); front matter
        // itself never reports "swift" twice.
        #expect(tags.filter { $0.tag == "swift" && $0.source == .frontMatter }.count == 1)
    }

    @Test func headingMarkerIsNotMistakenForATag() {
        let document = MarkdownDocument(source: "# Heading Title\n\nBody text.")
        let tags = TagScanner.scan(document)
        #expect(tags.isEmpty)
    }

    @Test func tagInsideFencedCodeBlockIsNotExtracted() {
        let document = MarkdownDocument(source: """
        Real tag: #real

        ```
        Not a tag: #fake
        ```
        """)
        let tags = TagScanner.scan(document)
        #expect(tags.map(\.tag) == ["real"])
    }

    @Test func numericOnlyHashIsNotATag() {
        let document = MarkdownDocument(source: "See issue #123 for details.")
        let tags = TagScanner.scan(document)
        #expect(tags.isEmpty)
    }

    @Test func hashInsideAWordIsNotATag() {
        let document = MarkdownDocument(source: "email me at name#example.com please")
        let tags = TagScanner.scan(document)
        #expect(tags.isEmpty)
    }
}
