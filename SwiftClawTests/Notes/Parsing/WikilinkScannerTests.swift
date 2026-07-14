import Foundation
import Testing
@testable import SwiftClaw

@Suite
struct WikilinkScannerTests {
    @Test func plainPageLink() {
        let document = MarkdownDocument(source: "See [[Page One]] for more.")
        let links = WikilinkScanner.scan(document)
        #expect(links.count == 1)
        #expect(links[0].kind == .link)
        #expect(links[0].pagePath == "Page One")
        #expect(links[0].heading == nil)
        #expect(links[0].alias == nil)
        #expect(links[0].normalizedStem == "page one")
    }

    @Test func pageWithAlias() {
        let document = MarkdownDocument(source: "[[Page One|display text]]")
        let links = WikilinkScanner.scan(document)
        #expect(links[0].pagePath == "Page One")
        #expect(links[0].alias == "display text")
    }

    @Test func pageWithHeadingFragment() {
        let document = MarkdownDocument(source: "[[Page One#Some Heading]]")
        let links = WikilinkScanner.scan(document)
        #expect(links[0].pagePath == "Page One")
        #expect(links[0].heading == "Some Heading")
    }

    @Test func headingFragmentWithAlias() {
        let document = MarkdownDocument(source: "[[Page One#Heading|shown]]")
        let links = WikilinkScanner.scan(document)
        #expect(links[0].pagePath == "Page One")
        #expect(links[0].heading == "Heading")
        #expect(links[0].alias == "shown")
    }

    @Test func embed() {
        let document = MarkdownDocument(source: "![[Diagram.png]]")
        let links = WikilinkScanner.scan(document)
        #expect(links[0].kind == .embed)
        #expect(links[0].pagePath == "Diagram.png")
    }

    @Test func normalizesFolderPathAndExtension() {
        let document = MarkdownDocument(source: "[[Folder/Sub/Page.md]]")
        let links = WikilinkScanner.scan(document)
        #expect(links[0].normalizedPath == "folder/sub/page")
        #expect(links[0].normalizedStem == "page")
    }

    @Test func wikilinkInsideFencedCodeBlockIsNotExtracted() {
        let document = MarkdownDocument(source: """
        Real: [[RealTarget]]

        ```
        Fake: [[NotACode]]
        ```
        """)
        let links = WikilinkScanner.scan(document)
        #expect(links.map(\.pagePath) == ["RealTarget"])
    }

    @Test func wikilinkInsideInlineCodeSpanIsNotExtracted() {
        let document = MarkdownDocument(source: "Use `[[NotALink]]` syntax, but [[RealLink]] works.")
        let links = WikilinkScanner.scan(document)
        #expect(links.map(\.pagePath) == ["RealLink"])
    }

    @Test func wikilinkInsideFrontMatterIsNotExtracted() {
        let document = MarkdownDocument(source: """
        ---
        related: [[NotALink]]
        ---
        Body has [[RealLink]].
        """)
        let links = WikilinkScanner.scan(document)
        #expect(links.map(\.pagePath) == ["RealLink"])
    }

    @Test func multipleLinksAreReturnedInSourceOrder() {
        let document = MarkdownDocument(source: "[[First]] then [[Second]]")
        let links = WikilinkScanner.scan(document)
        #expect(links.map(\.pagePath) == ["First", "Second"])
    }
}
