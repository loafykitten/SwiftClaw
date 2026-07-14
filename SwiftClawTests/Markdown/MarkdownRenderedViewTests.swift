import Foundation
import Testing
import Markdown
@testable import SwiftClaw

/// Regression coverage for the review finding that reading mode was handing
/// the *entire* source — including any leading YAML front matter — straight
/// to `Document(parsing:)`. Front matter is metadata, never document content,
/// so its keys/values/delimiters must never show up as rendered text. Tests
/// against `MarkdownRenderedView.body(of:)` directly rather than the SwiftUI
/// view tree, per the small-testable-helper preference over a UI snapshot
/// dependency.
struct MarkdownRenderedViewTests {
    @Test func bodyReturnsTheSourceUnchangedWhenThereIsNoFrontMatter() {
        let source = "# Title\n\nSome body text.\n"
        #expect(MarkdownRenderedView.body(of: source) == source)
    }

    @Test func bodyStripsALeadingFrontMatterBlockAndKeepsTheRestByteForByte() {
        let source = "---\ntitle: Hello\ntags: [a, b]\n---\n# Body Heading\n\nBody text.\n"
        let body = MarkdownRenderedView.body(of: source)

        #expect(!body.contains("title: Hello"))
        #expect(!body.contains("tags:"))
        #expect(!body.contains("---"))
        #expect(body == "# Body Heading\n\nBody text.\n")
    }

    @Test func aBodyThematicBreakIsNotMistakenForFrontMatterAndSurvivesIntact() {
        // No opening "---" at the very start, so this is not front matter at
        // all — the whole source, including its thematic break, is body.
        let source = "# Title\n\n---\n\nAfter the break.\n"
        #expect(MarkdownRenderedView.body(of: source) == source)
    }

    @Test func renderedBlocksNeverIncludeFrontMatterKeysOrDelimitersWhileTheBodySurvives() {
        let source = "---\ntitle: Hello\nsecret_key: opaque-value\n---\n# Body Heading\n\nBody text.\n"
        let blocks = Array(Document(parsing: MarkdownRenderedView.body(of: source), options: []).blockChildren)
        let renderedText = blocks.map { $0.format() }.joined(separator: "\n")

        #expect(!renderedText.contains("title:"))
        #expect(!renderedText.contains("secret_key"))
        #expect(!renderedText.contains("---"))
        #expect(renderedText.contains("Body Heading"))
        #expect(renderedText.contains("Body text."))
    }

    /// Regression coverage for the review finding that `MarkdownListView`
    /// always numbered ordered-list markers from 1, ignoring
    /// `Markdown.OrderedList.startIndex` — so a list written starting at
    /// `3.` rendered as `1.` `2.` `3.` instead of `3.` `4.` `5.`. Tests the
    /// static marker helper directly rather than the SwiftUI view tree.
    @Test func orderedListMarkersStartFromOneWhenTheSourceListDoes() {
        #expect(MarkdownListView.marker(checkbox: nil, ordered: true, startIndex: 1, index: 0) == "1.")
        #expect(MarkdownListView.marker(checkbox: nil, ordered: true, startIndex: 1, index: 1) == "2.")
        #expect(MarkdownListView.marker(checkbox: nil, ordered: true, startIndex: 1, index: 2) == "3.")
    }

    @Test func orderedListMarkersHonorANonOneStartIndex() {
        #expect(MarkdownListView.marker(checkbox: nil, ordered: true, startIndex: 3, index: 0) == "3.")
        #expect(MarkdownListView.marker(checkbox: nil, ordered: true, startIndex: 3, index: 1) == "4.")
        #expect(MarkdownListView.marker(checkbox: nil, ordered: true, startIndex: 3, index: 2) == "5.")
    }

    @Test func aParsedOrderedListStartingAtThreeReportsThatStartIndex() {
        let source = "3. Third\n4. Fourth\n5. Fifth\n"
        let document = Document(parsing: source)
        guard let list = document.blockChildren.first(where: { $0 is OrderedList }) as? OrderedList else {
            Issue.record("Expected to parse an OrderedList")
            return
        }
        #expect(list.startIndex == 3)
    }

    @Test func unorderedListMarkersIgnoreStartIndexAndUseABullet() {
        #expect(MarkdownListView.marker(checkbox: nil, ordered: false, startIndex: 1, index: 0) == "•")
        #expect(MarkdownListView.marker(checkbox: .checked, ordered: false, startIndex: 1, index: 0) == "☑")
        #expect(MarkdownListView.marker(checkbox: .unchecked, ordered: true, startIndex: 3, index: 0) == "☐")
    }
}
