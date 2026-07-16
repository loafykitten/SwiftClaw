import Foundation
#if os(macOS)
import AppKit

/// `NSTextStorageDelegate` is an Objective-C protocol with no actor metadata.
/// This wrapper carries the text view-owned storage through
/// `MainActor.assumeIsolated`; the delegate invariant below guarantees the
/// object never actually crosses threads.
private nonisolated struct MainActorTextStorage: @unchecked Sendable {
    let value: NSTextStorage
}

/// Restyles the editor's `NSTextStorage` as markdown source, attributes
/// only — it never inserts, deletes, or replaces a single character.
/// Ordinary edits restyle just the touched paragraph; edits that touch a
/// fence delimiter line (```` ``` ````/`~~~`) restyle from that point to the
/// end of the document, since toggling fence state changes how every
/// following line should look. Styling correctness is intentionally
/// approximate (best-effort regex-driven detection of headings, emphasis,
/// code, links/wikilinks, quotes/callouts, lists, front matter) — content
/// losslessness is what's non-negotiable, enforced by the `DEBUG` assertion
/// below.
@MainActor
final class MarkdownSourceHighlighter: NSObject, NSTextStorageDelegate {
    private var isStyling = false
    private var fenceState = FenceStateMachine()
    private let themeProvider: () -> MarkdownEditorTheme

    init(themeProvider: @escaping () -> MarkdownEditorTheme = { .current }) {
        self.themeProvider = themeProvider
    }

    /// `NSTextStorageDelegate` methods aren't isolation-annotated (it's an
    /// Objective-C protocol), but `NSTextStorage` only ever calls this while
    /// mutating on whatever thread owns the text view — main, for every
    /// caller in this app. `MainActor.assumeIsolated` documents that
    /// invariant instead of forcing an async hop that would let a second
    /// edit race this one.
    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        let mainActorTextStorage = MainActorTextStorage(value: textStorage)
        MainActor.assumeIsolated {
            self.restyle(mainActorTextStorage.value, editedMask: editedMask, editedRange: editedRange)
        }
    }

    private func restyle(_ textStorage: NSTextStorage, editedMask: NSTextStorageEditActions, editedRange: NSRange) {
        // Attribute-only mutations below re-enter `didProcessEditing` with
        // `.editedAttributes` (not `.editedCharacters`); `isStyling` guards
        // against acting on our own re-entrant calls, and the character-only
        // guard on the outer `guard` skips attribute-only edits entirely.
        guard !isStyling, editedMask.contains(.editedCharacters) else { return }
        isStyling = true
        defer { isStyling = false }

        #if DEBUG
        let before = textStorage.string
        #endif

        let nsString = textStorage.string as NSString
        let previousFenceStates = fenceState.insideFenceAtLineStart
        fenceState.recompute(for: textStorage.string)
        let frontMatterLineCount = Self.frontMatterLineCount(in: textStorage.string, nsString: nsString)

        let paragraphRange = nsString.paragraphRange(for: editedRange)
        let editedLineIndex = Self.lineNumber(in: nsString, at: paragraphRange.location)
        let styleRange = Self.rangeToRestyle(
            nsString: nsString,
            paragraphRange: paragraphRange,
            editedLineIndex: editedLineIndex,
            fenceState: fenceState,
            previousFenceStates: previousFenceStates
        )
        guard styleRange.location != NSNotFound, styleRange.length > 0 || nsString.length == 0 else { return }

        let theme = themeProvider()
        textStorage.addAttributes([.font: theme.bodyFont, .foregroundColor: theme.textColor], range: styleRange)
        styleLines(in: textStorage, range: styleRange, nsString: nsString, frontMatterLineCount: frontMatterLineCount, theme: theme)

        #if DEBUG
        assert(textStorage.string == before, "MarkdownSourceHighlighter must never alter characters, only attributes")
        #endif
    }

    /// Widens the paragraph-scoped range to the rest of the document when a
    /// fence delimiter line falls inside it — a toggled fence changes
    /// styling for everything after it, not just the edited paragraph.
    ///
    /// Checking only whether the *post-edit* line still reads as a fence
    /// delimiter isn't enough: deleting a marker character from an opening
    /// or closing fence (e.g. ` ``` ` → ` `` `) makes the edited line stop
    /// matching `isFenceDelimiter`, even though the fence parity for every
    /// following line just changed. So this also compares the per-line fence
    /// state recomputed for the new text against the state from before the
    /// edit, from the edited line onward, and conservatively widens whenever
    /// they diverge (including when the line count itself changed).
    private static func rangeToRestyle(
        nsString: NSString,
        paragraphRange: NSRange,
        editedLineIndex: Int,
        fenceState: FenceStateMachine,
        previousFenceStates: [Bool]
    ) -> NSRange {
        let toEndOfDocument = NSRange(location: paragraphRange.location, length: nsString.length - paragraphRange.location)

        let line = nsString.substring(with: paragraphRange).trimmingCharacters(in: .whitespacesAndNewlines)
        if FenceStateMachine.isFenceDelimiter(line) { return toEndOfDocument }

        let newStates = fenceState.insideFenceAtLineStart
        if previousFenceStates.count != newStates.count { return toEndOfDocument }
        for index in editedLineIndex..<newStates.count where previousFenceStates[index] != newStates[index] {
            return toEndOfDocument
        }

        return paragraphRange
    }

    private static func frontMatterLineCount(in source: String, nsString: NSString) -> Int {
        guard let frontMatter = FrontMatterBlock(source: source) else { return 0 }
        let upperBound = frontMatter.range.upperBound
        let location = source.utf16.distance(from: source.startIndex, to: upperBound)
        return lineNumber(in: nsString, at: location)
    }

    private static func lineNumber(in nsString: NSString, at location: Int) -> Int {
        guard location > 0, location <= nsString.length else { return 0 }
        var count = 0
        nsString.substring(to: location).unicodeScalars.forEach { if $0 == "\n" { count += 1 } }
        return count
    }

    private func styleLines(
        in textStorage: NSTextStorage,
        range: NSRange,
        nsString: NSString,
        frontMatterLineCount: Int,
        theme: MarkdownEditorTheme
    ) {
        var lineIndex = Self.lineNumber(in: nsString, at: range.location)
        nsString.enumerateSubstrings(in: range, options: [.byLines]) { substring, _, enclosingRange, _ in
            guard let substring else { return }
            if lineIndex < frontMatterLineCount {
                textStorage.addAttributes([.foregroundColor: theme.secondaryColor, .font: theme.monospacedFont], range: enclosingRange)
            } else {
                self.style(line: substring, range: enclosingRange, lineIndex: lineIndex, textStorage: textStorage, theme: theme)
            }
            lineIndex += 1
        }
    }

    private func style(line: String, range: NSRange, lineIndex: Int, textStorage: NSTextStorage, theme: MarkdownEditorTheme) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if fenceState.isInsideFence(atLine: lineIndex) || FenceStateMachine.isFenceDelimiter(trimmed) {
            textStorage.addAttributes([.font: theme.monospacedFont, .foregroundColor: theme.secondaryColor], range: range)
            return
        }

        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            textStorage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: range)
            return
        }

        if let level = Self.headingLevel(trimmed) {
            textStorage.addAttributes([.font: theme.headingFont(level: level), .foregroundColor: theme.headingColor], range: range)
            styleInline(in: textStorage, lineRange: range, line: line, theme: theme)
            return
        }

        if trimmed.hasPrefix(">") {
            textStorage.addAttribute(.foregroundColor, value: theme.quoteBarColor, range: range)
            styleInline(in: textStorage, lineRange: range, line: line, theme: theme)
            return
        }

        if Self.isListMarkerLine(trimmed) {
            styleInline(in: textStorage, lineRange: range, line: line, theme: theme)
            return
        }

        styleInline(in: textStorage, lineRange: range, line: line, theme: theme)
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6, trimmed.count > hashes.count, trimmed[trimmed.index(trimmed.startIndex, offsetBy: hashes.count)] == " " else {
            return nil
        }
        return hashes.count
    }

    private static func isListMarkerLine(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { return true }
        guard let firstSpace = trimmed.firstIndex(of: " ") else { return false }
        let prefix = trimmed[trimmed.startIndex..<firstSpace]
        guard prefix.hasSuffix("."), prefix.count > 1 else { return false }
        return prefix.dropLast().allSatisfy(\.isNumber)
    }

    // MARK: - Inline styling

    private static let boldPattern = try! NSRegularExpression(pattern: #"\*\*[^*]+\*\*|__[^_]+__"#)
    private static let italicPattern = try! NSRegularExpression(pattern: #"(?<![*\w])\*[^*]+\*(?!\*)|(?<![_\w])_[^_]+_(?!_)"#)
    private static let inlineCodePattern = try! NSRegularExpression(pattern: #"`[^`]+`"#)
    private static let linkPattern = try! NSRegularExpression(pattern: #"\[[^\]]*\]\([^)]+\)"#)
    private static let wikilinkPattern = try! NSRegularExpression(pattern: #"!?\[\[[^\[\]]+\]\]"#)

    private func styleInline(in textStorage: NSTextStorage, lineRange: NSRange, line: String, theme: MarkdownEditorTheme) {
        let nsLine = line as NSString
        func apply(_ regex: NSRegularExpression, _ attributes: [NSAttributedString.Key: Any]) {
            for match in regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                let absolute = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
                guard absolute.location + absolute.length <= textStorage.length else { continue }
                textStorage.addAttributes(attributes, range: absolute)
            }
        }

        apply(Self.wikilinkPattern, [.foregroundColor: theme.linkColor])
        apply(Self.linkPattern, [.foregroundColor: theme.linkColor])
        apply(Self.inlineCodePattern, [.font: theme.monospacedFont, .backgroundColor: theme.codeBackgroundColor])
        apply(Self.boldPattern, [.font: NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .boldFontMask)])
        apply(Self.italicPattern, [.font: NSFontManager.shared.convert(theme.bodyFont, toHaveTrait: .italicFontMask)])
    }
}

/// Tracks, for every line in the document, whether it starts inside an
/// open fenced code block (```` ``` ```` or `~~~`). Recomputed from scratch
/// on every edit — an O(document length) string scan with no attribute
/// writes — so a fence opened or closed earlier in the document is always
/// reflected correctly, even when the current edit lands on a later line.
struct FenceStateMachine {
    private(set) var insideFenceAtLineStart: [Bool] = []

    mutating func recompute(for text: String) {
        var states: [Bool] = []
        var inFence = false
        var fenceMarker: Character?
        var fenceRunLength = 0
        text.enumerateLines { line, _ in
            states.append(inFence)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inFence, let opener = Self.fenceOpener(of: trimmed) {
                inFence = true
                fenceMarker = opener.marker
                fenceRunLength = opener.runLength
            } else if inFence, let marker = fenceMarker,
                      let closer = Self.fenceCloser(of: trimmed),
                      closer.marker == marker, closer.runLength >= fenceRunLength {
                inFence = false
                fenceMarker = nil
                fenceRunLength = 0
            }
        }
        insideFenceAtLineStart = states
    }

    func isInsideFence(atLine line: Int) -> Bool {
        guard line >= 0, line < insideFenceAtLineStart.count else { return false }
        return insideFenceAtLineStart[line]
    }

    static func isFenceDelimiter(_ trimmedLine: String) -> Bool {
        fenceOpener(of: trimmedLine) != nil
    }

    /// A fence marker line's character and how many consecutive marker
    /// characters open it. Tracking the run length (not just the marker
    /// character) is what lets a longer opener, e.g. four backticks, stay
    /// open across a shorter run of the same character (three backticks)
    /// that appears inside its content — only a run at least as long as the
    /// opener's can close it, per CommonMark fenced-code-block rules. Openers
    /// are deliberately permissive about what follows the marker run (an
    /// info string, e.g. `` ```swift ``, is content, not part of the fence
    /// marker itself).
    private static func fenceOpener(of trimmedLine: String) -> (marker: Character, runLength: Int)? {
        guard let marker = trimmedLine.first, marker == "`" || marker == "~" else { return nil }
        let runLength = trimmedLine.prefix { $0 == marker }.count
        return runLength >= 3 ? (marker, runLength) : nil
    }

    /// A closing fence line, per CommonMark: unlike an opener, a closer may
    /// have nothing but spaces/tabs after its marker run. A line like
    /// `` ```swift `` inside an already-open fence is ordinary content (an
    /// inner code span happening to start a line), not a closer, even though
    /// it passes `fenceOpener`'s more permissive check.
    private static func fenceCloser(of trimmedLine: String) -> (marker: Character, runLength: Int)? {
        guard let marker = trimmedLine.first, marker == "`" || marker == "~" else { return nil }
        let runLength = trimmedLine.prefix { $0 == marker }.count
        guard runLength >= 3 else { return nil }
        let rest = trimmedLine.dropFirst(runLength)
        guard rest.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return (marker, runLength)
    }
}
#endif
