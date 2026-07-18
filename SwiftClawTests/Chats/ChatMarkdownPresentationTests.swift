import Foundation
import Testing
@testable import SwiftClaw

struct ChatMarkdownPresentationTests {
    @Test func presentationParsesBlocksAndFinalSourceCitationsTogether() {
        let presentation = ChatMarkdownBlockParser.presentation(from: """
            # Heading

            See [1].

            Sources
            1. Example https://example.com/path
            """)

        #expect(presentation.blocks.first == .heading(level: 1, text: "Heading"))
        #expect(presentation.citations[1] == URL(string: "https://example.com/path"))
    }

    @Test func presentationChangesWhenExactContentChanges() {
        let first = ChatMarkdownBlockParser.presentation(from: "First")
        let second = ChatMarkdownBlockParser.presentation(from: "Second")

        #expect(first != second)
        #expect(first.blocks == [.paragraph("First")])
        #expect(second.blocks == [.paragraph("Second")])
    }
}
