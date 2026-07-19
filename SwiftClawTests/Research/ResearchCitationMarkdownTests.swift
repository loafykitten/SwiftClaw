import Foundation
import Testing
@testable import SwiftClaw

@Suite("Research citation markdown")
struct ResearchCitationMarkdownTests {
    private let valid: Set<Int> = [1, 2, 3]

    private func link(_ index: Int) -> String {
        let url = MarkdownInlineRenderer.citationURL(forSourceIndex: index)!
        return "[\\[\(index)\\]](\(url.absoluteString))"
    }

    @Test func linksValidCitationsAndLeavesInvalidOnes() {
        let rendering = ResearchCitationMarkdown.linkingCitations(
            in: "A claim [1]. Adjacent [2] [3]. Unknown [9] stays.",
            validIndices: valid
        )
        #expect(rendering.markdown == "A claim \(link(1)). Adjacent \(link(2)) \(link(3)). Unknown [9] stays.")
        #expect(rendering.flaggedSourceIndices.isEmpty)
    }

    @Test func skipsFencedAndInlineCode() {
        let input = """
            Real citation [1].
            ```swift
            let array = values[1]
            ```
            Inline `values[2]` code, then real [2].
            """
        let rendering = ResearchCitationMarkdown.linkingCitations(in: input, validIndices: valid)
        #expect(rendering.markdown.contains("Real citation \(link(1))."))
        #expect(rendering.markdown.contains("let array = values[1]"))
        #expect(rendering.markdown.contains("`values[2]` code, then real \(link(2))."))
    }

    @Test func leavesExistingLinksIntact() {
        let input = "See [1](https://example.org) and cite [2]."
        let rendering = ResearchCitationMarkdown.linkingCitations(in: input, validIndices: valid)
        #expect(rendering.markdown == "See [1](https://example.org) and cite \(link(2)).")
    }

    @Test func flagsOnlySourcesInTheWarnedSentence() {
        // One markdown line is a whole paragraph — only the ⚠ sentence's
        // citations may be flagged, or verified sources in the same
        // paragraph would show a false "not verified" note.
        let input = """
            Supported claim [1].
            Fine here [1]. Dubious claim [2] ⚠. Another fine one [3].
            """
        let rendering = ResearchCitationMarkdown.linkingCitations(in: input, validIndices: valid)
        #expect(rendering.flaggedSourceIndices == [2])
        #expect(rendering.markdown.contains("\(link(2)) ⚠."))
    }

    @Test func emptyValidIndicesPassesThrough() {
        let input = "Nothing to do [1]."
        let rendering = ResearchCitationMarkdown.linkingCitations(in: input, validIndices: [])
        #expect(rendering.markdown == input)
    }
}
