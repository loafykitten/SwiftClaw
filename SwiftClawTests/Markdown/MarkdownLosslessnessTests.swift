import Foundation
import Testing
@testable import SwiftClaw

#if os(macOS)
import AppKit

/// The one non-negotiable invariant for `MarkdownSourceHighlighter`:
/// whatever attribute changes it makes, the text storage's `string` must
/// come out byte-for-byte identical to what went in. This drives a realistic
/// Obsidian-style corpus (callouts, wikilinks, embeds, nested tags, front
/// matter, fenced code) through a live `NSTextStorage` with the highlighter
/// attached exactly as `NoteEditorView` wires it up, then checks losslessness
/// after the initial styling pass and after simulated character-level edits.
@MainActor
struct MarkdownLosslessnessTests {
    private static let corpus = """
        ---
        title: Obsidian Corpus
        tags: [work, #nested/tag, "quoted tag"]
        ---
        # Heading One

        A paragraph with **bold**, *italic*, ~~strikethrough~~, and `inline code`.

        > [!note] A callout
        > with a second line and a [[Wikilink Page|alias]] inside it.

        - A list item with an embed: ![[diagram.png]]
        - Another item with a [[Plain Wikilink]]

        ```swift
        let x = 1
        let s = "not a [[wikilink]] inside code"
        ```

            indented code with `backticks` that must not be touched

        | A | B |
        |---|---|
        | 1 | 2 |

        ---

        Final paragraph after a thematic break.
        """

    /// Attaches the highlighter before inserting any content, matching
    /// `NoteEditorView.makeNSView`'s ordering exactly, then inserts the full
    /// corpus as one edit — the same path a freshly loaded note takes.
    private func makeStyledTextStorage(
        _ text: String,
        themeProvider: @escaping () -> MarkdownEditorTheme = { .current }
    ) -> (NSTextStorage, MarkdownSourceHighlighter) {
        let textStorage = NSTextStorage()
        let highlighter = MarkdownSourceHighlighter(themeProvider: themeProvider)
        textStorage.delegate = highlighter
        textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        return (textStorage, highlighter)
    }

    /// A theme whose fenced-code colors/fonts are unmistakably distinct from
    /// its ordinary body ones, so a test can tell "still styled as fenced
    /// code" apart from "recomputed back to ordinary text" by attribute
    /// value rather than by any real-world color/font identity.
    private static let probeTheme = MarkdownEditorTheme(
        backgroundColor: .clear,
        textColor: .red,
        secondaryColor: .blue,
        headingColor: .black,
        linkColor: .black,
        codeBackgroundColor: .clear,
        quoteBarColor: .black,
        bodyFont: .systemFont(ofSize: 12),
        monospacedFont: .systemFont(ofSize: 20)
    )

    @Test func stylingTheFullCorpusNeverChangesASingleCharacter() {
        let (textStorage, highlighter) = makeStyledTextStorage(Self.corpus)
        _ = highlighter
        #expect(textStorage.string == Self.corpus)
    }

    @Test func simulatedTypingOnlyChangesTheTypedCharacters() {
        let (textStorage, highlighter) = makeStyledTextStorage(Self.corpus)
        let insertionPoint = (Self.corpus as NSString).range(of: "Heading One").location
        textStorage.replaceCharacters(in: NSRange(location: insertionPoint, length: 0), with: "Extra ")

        var expected = Self.corpus
        let index = expected.range(of: "Heading One")!.lowerBound
        expected.insert(contentsOf: "Extra ", at: index)

        _ = highlighter
        #expect(textStorage.string == expected)
    }

    @Test func editingInsideAFencedCodeBlockOnlyChangesTheTypedCharacters() {
        let (textStorage, highlighter) = makeStyledTextStorage(Self.corpus)
        let target = "let x = 1"
        let location = (Self.corpus as NSString).range(of: target).location + target.count
        textStorage.replaceCharacters(in: NSRange(location: location, length: 0), with: " // note")

        var expected = Self.corpus
        let index = expected.range(of: target)!.upperBound
        expected.insert(contentsOf: " // note", at: index)

        _ = highlighter
        #expect(textStorage.string == expected)
    }

    @Test func deletingCharactersRemovesExactlyWhatWasDeleted() {
        let (textStorage, highlighter) = makeStyledTextStorage(Self.corpus)
        let target = "strikethrough"
        let nsRange = (Self.corpus as NSString).range(of: target)
        textStorage.replaceCharacters(in: nsRange, with: "")

        var expected = Self.corpus
        let range = expected.range(of: target)!
        expected.removeSubrange(range)

        _ = highlighter
        #expect(textStorage.string == expected)
    }

    @Test func togglingAFenceDelimiterRestylesWithoutChangingCharacters() {
        let (textStorage, highlighter) = makeStyledTextStorage(Self.corpus)
        // Editing the closing fence line touches the "restyle to end of
        // document" path in the fence-tracking state machine.
        let fenceRange = (Self.corpus as NSString).range(of: "```\n\n    indented")
        textStorage.replaceCharacters(in: NSRange(location: fenceRange.location, length: 3), with: "```")

        _ = highlighter
        #expect(textStorage.string == Self.corpus)
    }

    /// Regression coverage for the review finding that `MarkdownSourceHighlighter`
    /// recomputed fence state for the whole document but then only checked
    /// whether the *edited* line still read as a fence delimiter to decide
    /// how far to restyle — so deleting a backtick from an opening fence
    /// (making it too short to open a fence) left the previously-fenced
    /// content line's stale monospaced/secondary attributes in place, even
    /// though the recomputed fence state says it's no longer inside a fence.
    @Test func deletingAMarkerFromAnOpeningFenceRecomputesLaterLinesRatherThanLeavingStaleFenceStyling() {
        let text = "```\ncode line\n```\nafter\n"
        let (textStorage, highlighter) = makeStyledTextStorage(text, themeProvider: { Self.probeTheme })
        _ = highlighter

        let codeLineLocationBefore = (text as NSString).range(of: "code line").location
        let colorBefore = textStorage.attribute(.foregroundColor, at: codeLineLocationBefore, effectiveRange: nil) as? NSColor
        #expect(colorBefore == Self.probeTheme.secondaryColor)

        // Delete the first backtick of the opening fence, dropping it below
        // the 3-marker minimum so it no longer opens a fence at all.
        textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")

        var expected = text
        expected.removeFirst()
        #expect(textStorage.string == expected)

        let codeLineLocationAfter = (textStorage.string as NSString).range(of: "code line").location
        let colorAfter = textStorage.attribute(.foregroundColor, at: codeLineLocationAfter, effectiveRange: nil) as? NSColor
        #expect(colorAfter == Self.probeTheme.textColor)
    }

    /// Regression coverage for the same finding, on the closing side: deleting
    /// a marker from a *closing* fence means the fence never actually closes,
    /// so every following line should now read as still inside the fence —
    /// not retain whatever ordinary-text attributes they had before the edit.
    @Test func deletingAMarkerFromAClosingFenceRecomputesFollowingLinesRatherThanLeavingStaleOrdinaryStyling() {
        let text = "```\ncode\n```\nafter\n"
        let (textStorage, highlighter) = makeStyledTextStorage(text, themeProvider: { Self.probeTheme })
        _ = highlighter

        let afterLocationBefore = (text as NSString).range(of: "after").location
        let colorBefore = textStorage.attribute(.foregroundColor, at: afterLocationBefore, effectiveRange: nil) as? NSColor
        #expect(colorBefore == Self.probeTheme.textColor)

        let closingFenceLocation = (text as NSString).range(of: "```", options: .backwards).location
        textStorage.replaceCharacters(in: NSRange(location: closingFenceLocation, length: 1), with: "")

        var expected = text
        expected.remove(at: expected.index(expected.startIndex, offsetBy: closingFenceLocation))
        #expect(textStorage.string == expected)

        let afterLocationAfter = (textStorage.string as NSString).range(of: "after").location
        let colorAfter = textStorage.attribute(.foregroundColor, at: afterLocationAfter, effectiveRange: nil) as? NSColor
        #expect(colorAfter == Self.probeTheme.secondaryColor)
    }

    /// A tilde-fence counterpart to the backtick deletion coverage above,
    /// per the review finding calling out both marker characters.
    @Test func deletingATildeFromAnOpeningFenceRecomputesLaterLinesRatherThanLeavingStaleFenceStyling() {
        let text = "~~~\ncode line\n~~~\nafter\n"
        let (textStorage, highlighter) = makeStyledTextStorage(text, themeProvider: { Self.probeTheme })
        _ = highlighter

        let codeLineLocationBefore = (text as NSString).range(of: "code line").location
        let colorBefore = textStorage.attribute(.foregroundColor, at: codeLineLocationBefore, effectiveRange: nil) as? NSColor
        #expect(colorBefore == Self.probeTheme.secondaryColor)

        textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")

        var expected = text
        expected.removeFirst()
        #expect(textStorage.string == expected)

        let codeLineLocationAfter = (textStorage.string as NSString).range(of: "code line").location
        let colorAfter = textStorage.attribute(.foregroundColor, at: codeLineLocationAfter, effectiveRange: nil) as? NSColor
        #expect(colorAfter == Self.probeTheme.textColor)
    }
}
#endif
