import SwiftUI
import Testing
import Markdown
@testable import SwiftClaw

/// Regression coverage for the review finding that every inline run —
/// including ordinary, unstyled text — carried an explicit `.body` `Font`
/// attribute. Since an `AttributedString` run's explicit `font` wins over a
/// parent view's `.font()` modifier, that forced every heading and table
/// header back down to body size regardless of the `.font(...)` the caller
/// applied around `MarkdownInlineFlowView`. Bold/italic/strikethrough now
/// ride on `inlinePresentationIntent` instead, which composes with whatever
/// ambient font is in effect.
struct MarkdownInlineFlowViewTests {
    private func inlineChildren(ofFirstBlockIn source: String) -> [InlineMarkup] {
        let document = Document(parsing: source)
        guard let block = document.blockChildren.first(where: { $0 is Heading || $0 is Paragraph }) else {
            return []
        }
        if let heading = block as? Heading {
            return Array(heading.inlineChildren)
        }
        if let paragraph = block as? Paragraph {
            return Array(paragraph.inlineChildren)
        }
        return []
    }

    private func soleTextElement(for source: String) -> AttributedString {
        let elements = MarkdownInlineRenderer.flowElements(from: inlineChildren(ofFirstBlockIn: source))
        guard case .text(let attributed) = elements.first, elements.count == 1 else {
            Issue.record("Expected exactly one merged text element")
            return AttributedString()
        }
        return attributed
    }

    private func run(containing substring: String, in attributed: AttributedString) -> AttributedString.Runs.Run? {
        attributed.runs.first { run in
            String(attributed.characters[run.range]).contains(substring)
        }
    }

    @Test func ordinaryInlineTextCarriesNoExplicitFontSoItInheritsTheAmbientFont() {
        let attributed = soleTextElement(for: "# Plain heading text")
        guard let run = run(containing: "Plain heading text", in: attributed) else {
            Issue.record("Expected a run for the plain text")
            return
        }
        #expect(run.font == nil)
        #expect(run.inlinePresentationIntent == nil)
    }

    @Test func boldAndItalicRunsUseInlinePresentationIntentRatherThanAnExplicitFont() {
        let attributed = soleTextElement(for: "**bold** and *italic* text")

        guard let boldRun = run(containing: "bold", in: attributed) else {
            Issue.record("Expected a run for the bold text")
            return
        }
        #expect(boldRun.font == nil)
        #expect(boldRun.inlinePresentationIntent == .stronglyEmphasized)

        guard let italicRun = run(containing: "italic", in: attributed) else {
            Issue.record("Expected a run for the italic text")
            return
        }
        #expect(italicRun.font == nil)
        #expect(italicRun.inlinePresentationIntent == .emphasized)
    }

    @Test func linksAndWikilinksAlsoInheritTheAmbientFont() {
        let attributed = soleTextElement(for: "[web link](https://example.com) and [[local note]]")

        for label in ["web link", "local note"] {
            guard let linkedRun = run(containing: label, in: attributed) else {
                Issue.record("Expected a run for \(label)")
                return
            }
            #expect(linkedRun.font == nil)
            #expect(linkedRun.link != nil)
        }
    }

    @Test func inlineCodeStillCarriesAnExplicitMonospacedFont() {
        let attributed = soleTextElement(for: "some `code` here")
        guard let codeRun = run(containing: "code", in: attributed) else {
            Issue.record("Expected a run for the inline code")
            return
        }
        #expect(codeRun.font == .system(.body, design: .monospaced))
    }
}
