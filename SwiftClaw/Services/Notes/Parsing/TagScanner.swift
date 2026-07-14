import Foundation

/// A `#tag` occurrence, either declared as front-matter metadata or written
/// inline in the note body.
struct TagOccurrence: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case frontMatter
        case body
    }

    /// Lowercased canonical form (tags are treated case-insensitively).
    let tag: String
    let source: Source
    /// `nil` for front-matter tags, which have no single in-body location.
    let range: Range<String.Index>?
}

/// Extracts tags from a note: `tags:` front matter (inline list or YAML
/// dash-list form, via `FrontMatterBlock`) plus inline `#tag`/`#nested/tag`
/// occurrences in the body — skipping anything inside `MarkdownDocument`'s
/// excluded ranges so a `#tag`-looking token inside a fenced/inline code
/// span is never mistaken for a real tag.
nonisolated enum TagScanner {
    static func scan(_ document: MarkdownDocument) -> [TagOccurrence] {
        var occurrences: [TagOccurrence] = []
        var seenFrontMatterTags = Set<String>()

        if let frontMatter = document.frontMatter {
            for rawTag in frontMatter.tags {
                let normalized = normalize(rawTag)
                guard !normalized.isEmpty, seenFrontMatterTags.insert(normalized).inserted else { continue }
                occurrences.append(TagOccurrence(tag: normalized, source: .frontMatter, range: nil))
            }
        }

        occurrences.append(contentsOf: scanBody(document))
        return occurrences
    }

    private static func scanBody(_ document: MarkdownDocument) -> [TagOccurrence] {
        let source = document.source
        var results: [TagOccurrence] = []
        var index = source.startIndex

        while index < source.endIndex {
            guard source[index] == "#" else {
                index = source.index(after: index)
                continue
            }
            let hashIndex = index
            let afterHash = source.index(after: index)

            let precededByBoundary = hashIndex == source.startIndex || isBoundary(source[source.index(before: hashIndex)])
            guard precededByBoundary, afterHash < source.endIndex, isTagStart(source[afterHash]) else {
                index = source.index(after: index)
                continue
            }

            var end = afterHash
            while end < source.endIndex, isTagBody(source[end]) {
                end = source.index(after: end)
            }
            // A trailing `/` (e.g. "#project/" with nothing after) isn't part
            // of the tag's name.
            while end > afterHash, source[source.index(before: end)] == "/" {
                end = source.index(before: end)
            }

            let range = hashIndex..<end
            index = end
            guard !document.isExcluded(range) else { continue }

            let raw = String(source[afterHash..<end])
            guard isValidTag(raw) else { continue }
            results.append(TagOccurrence(tag: normalize(raw), source: .body, range: range))
        }

        return results
    }

    private static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || "([{\"'*_~<>".contains(character)
    }

    private static func isTagStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isTagBody(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "/"
    }

    /// A tag must contain at least one letter — `#123` is ordinary text
    /// (e.g. an issue reference), not a tag.
    private static func isValidTag(_ raw: String) -> Bool {
        !raw.isEmpty && raw.contains { $0.isLetter }
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
