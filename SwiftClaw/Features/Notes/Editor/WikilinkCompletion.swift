import Foundation

/// Pure detection of an in-progress `[[wikilink` the user just typed, plus
/// the fuzzy-ranked candidate list to show for it. Kept dependency-free
/// (`String`s and UTF-16 offsets in, plain values out) so it's directly
/// testable without an `NSTextView`, and so `NoteEditorController` can use it
/// without importing anything Notes-catalog-specific — candidates are always
/// passed in by the caller, never fetched here.
enum WikilinkCompletion {
    /// Converts a SwiftUI `TextSelection` index to the UTF-16 offset used by
    /// `NSTextView` and this completion engine. `samePosition(in:)` safely
    /// rejects an index that does not belong to the current text.
    static func utf16Offset(for index: String.Index, in text: String) -> Int? {
        guard let utf16Index = index.samePosition(in: text.utf16) else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
    }

    /// A `[[` the cursor is currently inside, not yet closed by `]]`, with no
    /// intervening `|`/`#`/newline — those mark the start of an alias or
    /// heading fragment, which this v1 doesn't offer completions for.
    struct Trigger: Equatable {
        /// UTF-16 range, relative to the scanned text, of the partial query
        /// typed so far (the text between `[[` and the cursor) — this is
        /// exactly the range a chosen completion replaces.
        let queryRange: NSRange
        let query: String
        /// Whether a `]]` already sits immediately after the cursor (e.g. the
        /// user is editing inside an already-closed `[[...]]` pair). When
        /// true, `completionText(for:closingBracketsAlreadyPresent:)` must
        /// not append another `]]`, or acceptance would duplicate it.
        let hasTrailingClosingBrackets: Bool
    }

    /// One ranked candidate to show in the completion list.
    struct Candidate: Equatable {
        let note: NoteSummary
        let match: FuzzyMatcher.Match
    }

    /// Scans `text` backward from `cursorLocation` (a UTF-16 offset, matching
    /// `NSTextView.selectedRange().location`) for an unclosed `[[`. Returns
    /// `nil` when the cursor isn't inside one — including when a `]]`,
    /// newline, `|`, or `#` already appears between the `[[` and the cursor.
    /// A later `]]` in the same target also suppresses completion unless it is
    /// immediately at the caret: replacing only the prefix of a closed target
    /// would otherwise leave its suffix behind.
    static func trigger(in text: String, cursorLocation: Int) -> Trigger? {
        let nsText = text as NSString
        guard cursorLocation >= 0, cursorLocation <= nsText.length else { return nil }

        var openLocation: Int?
        var searchEnd = cursorLocation
        while searchEnd >= 2 {
            let candidateRange = NSRange(location: searchEnd - 2, length: 2)
            if nsText.substring(with: candidateRange) == "[[" {
                openLocation = searchEnd
                break
            }
            searchEnd -= 1
        }
        guard let openLocation else { return nil }

        let queryRange = NSRange(location: openLocation, length: cursorLocation - openLocation)
        let query = nsText.substring(with: queryRange)
        guard !query.contains(where: { $0 == "]" || $0 == "|" || $0 == "#" || $0 == "\n" }) else { return nil }

        var trailingLocation = cursorLocation
        while trailingLocation < nsText.length {
            let remainingLength = nsText.length - trailingLocation
            if remainingLength >= 2,
               nsText.substring(with: NSRange(location: trailingLocation, length: 2)) == "]]" {
                let hasTrailingClosingBrackets = trailingLocation == cursorLocation
                guard hasTrailingClosingBrackets else { return nil }
                return Trigger(queryRange: queryRange, query: query, hasTrailingClosingBrackets: true)
            }

            let character = nsText.substring(with: NSRange(location: trailingLocation, length: 1))
            // An alias, heading, or line boundary means accepting a completion
            // here would insert `]]` before the remaining wikilink content.
            guard character != "|", character != "#", character != "\n" else { return nil }
            trailingLocation += 1
        }

        return Trigger(queryRange: queryRange, query: query, hasTrailingClosingBrackets: false)
    }

    /// Ranks `candidates` against `query` via `FuzzyMatcher`, best match
    /// first, ties broken by title. `excluding` (typically the currently
    /// open note) is left out — linking a note to itself by autocomplete is
    /// rarely intentional, and it's always still possible to type it by hand.
    static func rankedCandidates(query: String, notes: [NoteSummary], excluding currentPath: String? = nil, limit: Int = 8) -> [Candidate] {
        guard !query.isEmpty else {
            return notes
                .filter { $0.relativePath != currentPath }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .prefix(limit)
                .map { Candidate(note: $0, match: FuzzyMatcher.Match(score: 0, ranges: [])) }
        }
        return notes
            .filter { $0.relativePath != currentPath }
            .compactMap { note -> Candidate? in
                guard let match = FuzzyMatcher.match(query: query, in: note.title) else { return nil }
                return Candidate(note: note, match: match)
            }
            .sorted { lhs, rhs in
                lhs.match.score != rhs.match.score
                    ? lhs.match.score > rhs.match.score
                    : lhs.note.title.localizedCaseInsensitiveCompare(rhs.note.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The replacement text for choosing `note`: the vault-relative path with
    /// its `.md` extension stripped (matches `WikilinkScanner.normalize`'s
    /// resolution key) plus the closing `]]`, so the inserted link is a
    /// complete, resolved wikilink immediately — and so the cursor lands past
    /// the closing brackets, which is what keeps `trigger(in:cursorLocation:)`
    /// from re-detecting an unclosed `[[` on the very next keystroke
    /// notification and reopening the popup it was just dismissed from.
    ///
    /// When `closingBracketsAlreadyPresent` is true (the cursor sits right
    /// before an already-typed `]]`, e.g. the user is editing inside an
    /// existing link), the existing pair is reused instead of appending
    /// another one — otherwise acceptance would leave four closing brackets.
    static func completionText(for note: NoteSummary, closingBracketsAlreadyPresent: Bool = false) -> String {
        let path = note.relativePath.hasSuffix(".md") ? String(note.relativePath.dropLast(3)) : note.relativePath
        return closingBracketsAlreadyPresent ? path : path + "]]"
    }
}
