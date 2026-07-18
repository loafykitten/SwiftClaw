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
/// Ordinary edits restyle just the touched lines; edits that change fence
/// state (```` ``` ````/`~~~`) widen the range until the cached state
/// converges again. Styling correctness is intentionally
/// approximate (best-effort regex-driven detection of headings, emphasis,
/// code, links/wikilinks, quotes/callouts, lists, front matter) — content
/// losslessness is what's non-negotiable, enforced by the `DEBUG` assertion
/// below.
@MainActor
final class MarkdownSourceHighlighter: NSObject, NSTextStorageDelegate {
    /// Markdown syntax styling is intentionally disabled above one MiB of
    /// UTF-8 source. Large notes remain readable without paying for regex and
    /// fence-state work on every keystroke.
    static let maximumStyledUTF8ByteCount = 1 * 1024 * 1024

    private var isStyling = false
    private var isInLargeDocumentMode = false
    private var utf8ByteCount = 0
    private var cachedUTF16Length = 0
    private var utf8ExtraOneByteLocations = IndexSet()
    private var utf8ExtraTwoByteLocations = IndexSet()
    private var utf8ExtraThreeByteLocations = IndexSet()
    private var utf8MinusOneByteLocations = IndexSet()
    private var lineStarts = [0]
    private var hasStructuralCache = false
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
            self.restyle(
                mainActorTextStorage.value,
                editedMask: editedMask,
                editedRange: editedRange,
                changeInLength: delta
            )
        }
    }

    private func restyle(
        _ textStorage: NSTextStorage,
        editedMask: NSTextStorageEditActions,
        editedRange: NSRange,
        changeInLength delta: Int
    ) {
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
        updateUTF8Cache(nsString: nsString, editedRange: editedRange, changeInLength: delta)
        let exceedsStylingLimit = utf8ByteCount > Self.maximumStyledUTF8ByteCount
        if exceedsStylingLimit {
            let theme = themeProvider()
            if !isInLargeDocumentMode {
                // Clear all syntax-specific attributes exactly once when the
                // document crosses the limit, leaving a plain readable base.
                textStorage.setAttributes(
                    [.font: theme.bodyFont, .foregroundColor: theme.textColor],
                    range: NSRange(location: 0, length: nsString.length)
                )
                invalidateStructuralCache()
                isInLargeDocumentMode = true
            } else if nsString.length > 0 {
                // Newly typed text can inherit syntax attributes from its
                // neighbours. Normalize only the touched paragraph; do not
                // repeatedly clear the whole large document.
                let range = nsString.paragraphRange(for: editedRange)
                textStorage.addAttributes([.font: theme.bodyFont, .foregroundColor: theme.textColor], range: range)
            }
            return
        }

        let wasInLargeDocumentMode = isInLargeDocumentMode
        isInLargeDocumentMode = false
        let styleRange: NSRange
        if wasInLargeDocumentMode || !hasStructuralCache {
            rebuildStructuralCache(nsString: nsString)
            styleRange = NSRange(location: 0, length: nsString.length)
        } else {
            styleRange = updateStructuralCache(
                nsString: nsString,
                editedRange: editedRange,
                changeInLength: delta
            )
        }
        let frontMatterLineCount = Self.frontMatterLineCount(
            in: textStorage.string,
            lineStarts: lineStarts
        )
        guard styleRange.location != NSNotFound, styleRange.length > 0 || nsString.length == 0 else { return }

        let theme = themeProvider()
        let baseAttributes: [NSAttributedString.Key: Any] = [.font: theme.bodyFont, .foregroundColor: theme.textColor]
        if wasInLargeDocumentMode {
            // Remove any attributes inherited during large-document editing
            // before restoring syntax styling across the shrunken document.
            textStorage.setAttributes(baseAttributes, range: styleRange)
        } else {
            textStorage.addAttributes(baseAttributes, range: styleRange)
        }
        styleLines(in: textStorage, range: styleRange, nsString: nsString, frontMatterLineCount: frontMatterLineCount, theme: theme)

        #if DEBUG
        assert(textStorage.string == before, "MarkdownSourceHighlighter must never alter characters, only attributes")
        #endif
    }

    /// The byte-width cache is invalidated by every character edit via the
    /// delegate's edited range and length delta. It makes threshold checks
    /// proportional to the replacement instead of the whole document.
    private func updateUTF8Cache(nsString: NSString, editedRange: NSRange, changeInLength delta: Int) {
        let oldDocumentLength = nsString.length - delta
        let oldEditedLength = editedRange.length - delta
        let oldEditedRange = NSRange(location: editedRange.location, length: oldEditedLength)
        let cacheMatchesOldDocument = oldDocumentLength >= 0
            && oldEditedLength >= 0
            && NSMaxRange(oldEditedRange) <= oldDocumentLength
            && NSMaxRange(editedRange) <= nsString.length
            && cachedUTF16Length == oldDocumentLength

        guard cacheMatchesOldDocument else {
            rebuildUTF8Cache(nsString)
            invalidateStructuralCache()
            return
        }

        let replacementMetrics = Self.utf8Metrics(in: nsString.substring(with: editedRange))
        guard replacementMetrics.utf16Length == editedRange.length else {
            rebuildUTF8Cache(nsString)
            invalidateStructuralCache()
            return
        }

        let oldRange = oldEditedRange.location..<NSMaxRange(oldEditedRange)
        let removedByteCount = oldEditedLength
            + utf8ExtraOneByteLocations.intersection(IndexSet(integersIn: oldRange)).count
            + 2 * utf8ExtraTwoByteLocations.intersection(IndexSet(integersIn: oldRange)).count
            + 3 * utf8ExtraThreeByteLocations.intersection(IndexSet(integersIn: oldRange)).count
            - utf8MinusOneByteLocations.intersection(IndexSet(integersIn: oldRange)).count
        updateUTF8Locations(
            replacing: oldRange,
            changeInLength: delta,
            replacementMetrics: replacementMetrics
        )
        utf8ByteCount += replacementMetrics.byteCount - removedByteCount
        cachedUTF16Length = nsString.length
    }

    private func rebuildUTF8Cache(_ nsString: NSString) {
        let metrics = Self.utf8Metrics(in: nsString as String)
        cachedUTF16Length = metrics.utf16Length
        utf8ByteCount = metrics.byteCount
        utf8ExtraOneByteLocations = IndexSet(metrics.extraOneByteLocations)
        utf8ExtraTwoByteLocations = IndexSet(metrics.extraTwoByteLocations)
        utf8ExtraThreeByteLocations = IndexSet(metrics.extraThreeByteLocations)
        utf8MinusOneByteLocations = IndexSet(metrics.minusOneByteLocations)
    }

    private func updateUTF8Locations(
        replacing oldRange: Range<Int>,
        changeInLength delta: Int,
        replacementMetrics: UTF8Metrics
    ) {
        func update(_ locations: inout IndexSet, inserting replacementLocations: [Int]) {
            locations.remove(integersIn: oldRange)
            let shiftedLocations = NSMutableIndexSet(indexSet: locations)
            shiftedLocations.shiftIndexesStarting(at: oldRange.upperBound, by: delta)
            locations = shiftedLocations as IndexSet
            for location in replacementLocations {
                locations.insert(oldRange.lowerBound + location)
            }
        }

        update(&utf8ExtraOneByteLocations, inserting: replacementMetrics.extraOneByteLocations)
        update(&utf8ExtraTwoByteLocations, inserting: replacementMetrics.extraTwoByteLocations)
        update(&utf8ExtraThreeByteLocations, inserting: replacementMetrics.extraThreeByteLocations)
        update(&utf8MinusOneByteLocations, inserting: replacementMetrics.minusOneByteLocations)
    }

    private struct UTF8Metrics {
        var utf16Length = 0
        var byteCount = 0
        var extraOneByteLocations: [Int] = []
        var extraTwoByteLocations: [Int] = []
        var extraThreeByteLocations: [Int] = []
        var minusOneByteLocations: [Int] = []
    }

    private static func utf8Metrics(in text: String) -> UTF8Metrics {
        let codeUnits = Array(text.utf16)
        var metrics = UTF8Metrics(utf16Length: codeUnits.count)
        var index = 0
        while index < codeUnits.count {
            let codeUnit = codeUnits[index]
            if (0xD800...0xDBFF).contains(codeUnit),
               index + 1 < codeUnits.count,
               (0xDC00...0xDFFF).contains(codeUnits[index + 1]) {
                metrics.byteCount += 4
                metrics.extraThreeByteLocations.append(index)
                metrics.minusOneByteLocations.append(index + 1)
                index += 2
            } else {
                if codeUnit <= 0x7F {
                    metrics.byteCount += 1
                } else if codeUnit <= 0x7FF {
                    metrics.byteCount += 2
                    metrics.extraOneByteLocations.append(index)
                } else {
                    metrics.byteCount += 3
                    metrics.extraTwoByteLocations.append(index)
                }
                index += 1
            }
        }
        return metrics
    }

    /// Line starts and fence contexts are invalidated by the same character
    /// edit signal. Large-document mode drops them because it never performs
    /// syntax styling; crossing back below the limit rebuilds them once.
    private func invalidateStructuralCache() {
        lineStarts = [0]
        fenceState = FenceStateMachine()
        hasStructuralCache = false
    }

    private func rebuildStructuralCache(nsString: NSString) {
        lineStarts = Self.computeLineStarts(in: nsString)
        fenceState.recompute(in: nsString, lineStarts: lineStarts)
        hasStructuralCache = true
    }

    private func updateStructuralCache(
        nsString: NSString,
        editedRange: NSRange,
        changeInLength delta: Int
    ) -> NSRange {
        let oldDocumentLength = nsString.length - delta
        let oldEditedLength = editedRange.length - delta
        guard oldDocumentLength >= 0, oldEditedLength >= 0 else {
            rebuildStructuralCache(nsString: nsString)
            return NSRange(location: 0, length: nsString.length)
        }

        let oldFirstLine = Self.lineIndex(at: editedRange.location, lineStarts: lineStarts)
        let oldLastLine = Self.lineIndex(
            at: min(editedRange.location + oldEditedLength, oldDocumentLength),
            lineStarts: lineStarts
        )
        let oldChangedLines = oldFirstLine..<(oldLastLine + 1)

        updateLineStarts(
            nsString: nsString,
            editedRange: editedRange,
            oldEditedLength: oldEditedLength,
            changeInLength: delta
        )

        let newFirstLine = Self.lineIndex(at: editedRange.location, lineStarts: lineStarts)
        let newLastLine = Self.lineIndex(
            at: min(NSMaxRange(editedRange), nsString.length),
            lineStarts: lineStarts
        )
        let newChangedLines = newFirstLine..<(newLastLine + 1)
        let lastAffectedLine = fenceState.update(
            in: nsString,
            lineStarts: lineStarts,
            replacing: oldChangedLines,
            with: newChangedLines
        )
        let upperLine = max(newLastLine, lastAffectedLine)
        let upperBound = upperLine + 1 < lineStarts.count ? lineStarts[upperLine + 1] : nsString.length
        return NSRange(location: lineStarts[newFirstLine], length: upperBound - lineStarts[newFirstLine])
    }

    private func updateLineStarts(
        nsString: NSString,
        editedRange: NSRange,
        oldEditedLength: Int,
        changeInLength delta: Int
    ) {
        let oldEnd = editedRange.location + oldEditedLength
        let removalStart = Self.upperBound(of: editedRange.location, in: lineStarts)
        let removalEnd = Self.upperBound(of: oldEnd, in: lineStarts)
        lineStarts.removeSubrange(removalStart..<removalEnd)

        for index in removalStart..<lineStarts.count where lineStarts[index] > oldEnd {
            lineStarts[index] += delta
        }

        var insertedStarts: [Int] = []
        var searchLocation = editedRange.location
        let editedEnd = NSMaxRange(editedRange)
        while searchLocation < editedEnd {
            let newline = nsString.range(
                of: "\n",
                options: [],
                range: NSRange(location: searchLocation, length: editedEnd - searchLocation)
            )
            guard newline.location != NSNotFound else { break }
            insertedStarts.append(NSMaxRange(newline))
            searchLocation = NSMaxRange(newline)
        }
        lineStarts.insert(contentsOf: insertedStarts, at: removalStart)
    }

    private static func computeLineStarts(in nsString: NSString) -> [Int] {
        var starts = [0]
        var searchLocation = 0
        while searchLocation < nsString.length {
            let newline = nsString.range(
                of: "\n",
                options: [],
                range: NSRange(location: searchLocation, length: nsString.length - searchLocation)
            )
            guard newline.location != NSNotFound else { break }
            starts.append(NSMaxRange(newline))
            searchLocation = NSMaxRange(newline)
        }
        return starts
    }

    private static func lineIndex(at location: Int, lineStarts: [Int]) -> Int {
        max(0, upperBound(of: location, in: lineStarts) - 1)
    }

    private static func upperBound(of value: Int, in values: [Int]) -> Int {
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if values[middle] <= value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func frontMatterLineCount(in source: String, lineStarts: [Int]) -> Int {
        guard let frontMatter = FrontMatterBlock(source: source) else { return 0 }
        let upperBound = frontMatter.range.upperBound
        let location = source.utf16.distance(from: source.startIndex, to: upperBound)
        return lineIndex(at: location, lineStarts: lineStarts)
    }

    private func styleLines(
        in textStorage: NSTextStorage,
        range: NSRange,
        nsString: NSString,
        frontMatterLineCount: Int,
        theme: MarkdownEditorTheme
    ) {
        var lineIndex = Self.lineIndex(at: range.location, lineStarts: lineStarts)
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

/// Tracks the complete fence context at each line start. The highlighter
/// replaces signatures only for lines touched by an edit, then carries the
/// resulting context forward until it matches the cached suffix again.
struct FenceStateMachine {
    private struct FenceContext: Equatable {
        var marker: Character?
        var runLength = 0

        static let outside = FenceContext(marker: nil, runLength: 0)
    }

    private struct LineSignature {
        let opener: (marker: Character, runLength: Int)?
        let closer: (marker: Character, runLength: Int)?
    }

    private var contexts: [FenceContext] = []
    private var signatures: [LineSignature] = []

    var insideFenceAtLineStart: [Bool] {
        contexts.map { $0.marker != nil }
    }

    mutating func recompute(for text: String) {
        let nsString = text as NSString
        var lineStarts = [0]
        var searchLocation = 0
        while searchLocation < nsString.length {
            let newline = nsString.range(
                of: "\n",
                options: [],
                range: NSRange(location: searchLocation, length: nsString.length - searchLocation)
            )
            guard newline.location != NSNotFound else { break }
            lineStarts.append(NSMaxRange(newline))
            searchLocation = NSMaxRange(newline)
        }
        recompute(in: nsString, lineStarts: lineStarts)
    }

    mutating func recompute(in text: NSString, lineStarts: [Int]) {
        signatures = lineStarts.indices.map { Self.signature(in: text, line: $0, lineStarts: lineStarts) }
        contexts = Array(repeating: .outside, count: signatures.count)
        var context = FenceContext.outside
        for index in signatures.indices {
            contexts[index] = context
            context = Self.context(after: signatures[index], startingWith: context)
        }
    }

    /// Returns the last line whose styling may have changed. Cached suffix
    /// contexts are preserved when line counts shift, so equality at the
    /// first unchanged line proves all following contexts are unchanged too.
    mutating func update(
        in text: NSString,
        lineStarts: [Int],
        replacing oldLines: Range<Int>,
        with newLines: Range<Int>
    ) -> Int {
        guard oldLines.lowerBound >= 0,
              oldLines.upperBound <= signatures.count,
              newLines.lowerBound == oldLines.lowerBound,
              newLines.upperBound <= lineStarts.count
        else {
            recompute(in: text, lineStarts: lineStarts)
            return max(0, lineStarts.count - 1)
        }

        let replacements = newLines.map { Self.signature(in: text, line: $0, lineStarts: lineStarts) }
        signatures.replaceSubrange(oldLines, with: replacements)
        contexts.replaceSubrange(
            oldLines,
            with: Array(repeating: FenceContext.outside, count: replacements.count)
        )
        guard signatures.count == lineStarts.count, contexts.count == lineStarts.count else {
            recompute(in: text, lineStarts: lineStarts)
            return max(0, lineStarts.count - 1)
        }

        let firstLine = newLines.lowerBound
        var context = firstLine == 0
            ? FenceContext.outside
            : Self.context(after: signatures[firstLine - 1], startingWith: contexts[firstLine - 1])
        var lastAffectedLine = max(firstLine, newLines.upperBound - 1)

        for index in firstLine..<signatures.count {
            if index >= newLines.upperBound, contexts[index] == context {
                break
            }
            contexts[index] = context
            lastAffectedLine = index
            context = Self.context(after: signatures[index], startingWith: context)
        }
        return lastAffectedLine
    }

    func isInsideFence(atLine line: Int) -> Bool {
        guard line >= 0, line < contexts.count else { return false }
        return contexts[line].marker != nil
    }

    static func isFenceDelimiter(_ trimmedLine: String) -> Bool {
        fenceOpener(of: trimmedLine) != nil
    }

    private static func signature(in text: NSString, line: Int, lineStarts: [Int]) -> LineSignature {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : text.length
        let lineText = text.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LineSignature(opener: fenceOpener(of: lineText), closer: fenceCloser(of: lineText))
    }

    private static func context(after line: LineSignature, startingWith context: FenceContext) -> FenceContext {
        if let marker = context.marker {
            guard let closer = line.closer,
                  closer.marker == marker,
                  closer.runLength >= context.runLength
            else { return context }
            return .outside
        }
        guard let opener = line.opener else { return context }
        return FenceContext(marker: opener.marker, runLength: opener.runLength)
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
