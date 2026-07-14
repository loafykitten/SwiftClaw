import Foundation
import Testing
@testable import SwiftClaw

struct MarkdownDocumentTests {
    @Test func headingOutlineCapturesLevelsAndText() {
        let source = """
        # Title

        Some paragraph text.

        ## Section One

        More text.

        ### Subsection
        """
        let document = MarkdownDocument(source: source)
        #expect(document.headings.map(\.level) == [1, 2, 3])
        #expect(document.headings.map(\.text) == ["Title", "Section One", "Subsection"])
        for heading in document.headings {
            #expect(source[heading.range].contains(heading.text))
        }
    }

    @Test func headingSourceRangesPointBackAtTheOriginalText() {
        let source = "# Hello World\n\nBody.\n"
        let document = MarkdownDocument(source: source)
        let heading = try! #require(document.headings.first)
        #expect(source[heading.range] == "# Hello World")
    }

    @Test func fencedCodeBlockIsExcluded() {
        let source = """
        Intro text.

        ```swift
        let x = 1
        ```

        Outro text.
        """
        let document = MarkdownDocument(source: source)
        #expect(document.excludedRanges.count == 1)
        let excludedText = source[document.excludedRanges[0]]
        #expect(excludedText.contains("let x = 1"))
        #expect(!excludedText.contains("Intro"))
        #expect(!excludedText.contains("Outro"))
    }

    @Test func indentedCodeBlockIsExcluded() {
        let source = "Paragraph.\n\n    indented code line\n    second line\n\nAfter.\n"
        let document = MarkdownDocument(source: source)
        #expect(document.excludedRanges.count == 1)
        let excludedText = source[document.excludedRanges[0]]
        #expect(excludedText.contains("indented code line"))
    }

    @Test func inlineCodeSpanIsExcluded() {
        let source = "Use `let x = 1` in your code."
        let document = MarkdownDocument(source: source)
        #expect(document.excludedRanges.count == 1)
        #expect(source[document.excludedRanges[0]] == "`let x = 1`")
    }

    @Test func frontMatterIsExcludedAsALeadingRange() {
        let source = "---\ntitle: Hello\ntags: [a]\n---\n# Body\n"
        let document = MarkdownDocument(source: source)
        #expect(document.frontMatter != nil)
        #expect(document.excludedRanges.contains { source[$0].hasPrefix("---\ntitle:") })
        // The heading in the body is still discovered outside the front matter.
        #expect(document.headings.map(\.text) == ["Body"])
    }

    @Test func isExcludedReportsWhetherAnIndexOrRangeOverlapsExcludedContent() {
        let source = "Text `code` more text."
        let document = MarkdownDocument(source: source)
        let codeRange = document.excludedRanges[0]
        #expect(document.isExcluded(codeRange.lowerBound))
        #expect(document.isExcluded(codeRange))
        let plainStart = source.startIndex
        #expect(!document.isExcluded(plainStart))
    }

    @Test func unicodeContentBeforeAHeadingDoesNotShiftItsRange() {
        // Multi-byte UTF-8 content (emoji, combining characters) before a
        // heading must not throw off the SourceLocation -> String.Index
        // conversion, which operates on UTF-8 byte offsets internally.
        let source = "Some é™Ÿ unicode text 🎉 first.\n\n# Héading\n\nBody.\n"
        let document = MarkdownDocument(source: source)
        let heading = try! #require(document.headings.first)
        #expect(heading.text == "Héading")
        #expect(source[heading.range] == "# Héading")
    }

    @Test func inlineCodeInsideAHeadingIsBothInTheOutlineAndExcluded() {
        let source = "## Using `code` in a heading\n"
        let document = MarkdownDocument(source: source)
        #expect(document.headings.first?.text == "Using `code` in a heading")
        #expect(document.excludedRanges.count == 1)
        #expect(source[document.excludedRanges[0]] == "`code`")
    }

    @Test func documentWithNoSpecialConstructsHasNoExcludedRangesOrHeadings() {
        let source = "Just a plain paragraph with nothing special.\n"
        let document = MarkdownDocument(source: source)
        #expect(document.excludedRanges.isEmpty)
        #expect(document.headings.isEmpty)
        #expect(document.frontMatter == nil)
    }
}
