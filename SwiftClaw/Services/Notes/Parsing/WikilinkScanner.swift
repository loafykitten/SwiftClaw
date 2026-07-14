import Foundation

/// Whether a `[[...]]` occurrence is a plain link or an `![[...]]` embed.
enum WikilinkKind: String, Sendable, Equatable {
    case link
    case embed
}

/// One `[[page]]` / `[[page|alias]]` / `[[page#heading]]` / `![[page]]`
/// occurrence found in a note's body. Carries both the original display
/// data (`pagePath`/`heading`/`alias`, exactly as written) and normalized
/// forms used for resolution, so `NoteLinkGraph` never has to re-derive
/// display text from a normalized value.
struct WikilinkOccurrence: Sendable, Equatable {
    let kind: WikilinkKind
    /// The target's page/path portion, original case, with any `#heading`
    /// fragment and `|alias` already split off. Empty for a same-note
    /// heading link (`[[#Heading]]`).
    let pagePath: String
    let heading: String?
    let alias: String?
    /// Lowercased, `.md`-stripped form of `pagePath` — used to match
    /// against an existing note's relative path for exact resolution.
    let normalizedPath: String
    /// The last path component of `normalizedPath` — used for filename-stem
    /// resolution when no exact path match exists.
    let normalizedStem: String
    let range: Range<String.Index>
}

/// Extracts Obsidian-style wikilinks from a note's body, skipping anything
/// inside `MarkdownDocument`'s excluded ranges (front matter, fenced/indented
/// code blocks, inline code spans) so a `[[link]]` written inside a code
/// fence — shown as a literal example, not a real reference — never becomes
/// a graph edge.
nonisolated enum WikilinkScanner {
    /// Scans `document.source` for wikilink/embed occurrences, in source order.
    static func scan(_ document: MarkdownDocument) -> [WikilinkOccurrence] {
        let source = document.source
        var occurrences: [WikilinkOccurrence] = []
        var searchStart = source.startIndex

        while let openRange = source.range(of: "[[", range: searchStart..<source.endIndex) {
            guard let closeRange = source.range(of: "]]", range: openRange.upperBound..<source.endIndex) else {
                break
            }
            searchStart = closeRange.upperBound

            let inner = source[openRange.upperBound..<closeRange.lowerBound]
            // A real wikilink never spans a line break; treat a `[[`/`]]`
            // pair that does as an unrelated pair of double brackets.
            guard !inner.contains("\n") else { continue }

            let isEmbed = openRange.lowerBound > source.startIndex
                && source[source.index(before: openRange.lowerBound)] == "!"
            let fullRange = (isEmbed ? source.index(before: openRange.lowerBound) : openRange.lowerBound)..<closeRange.upperBound
            guard !document.isExcluded(fullRange) else { continue }

            occurrences.append(parse(inner: String(inner), kind: isEmbed ? .embed : .link, range: fullRange))
        }

        return occurrences
    }

    private static func parse(inner: String, kind: WikilinkKind, range: Range<String.Index>) -> WikilinkOccurrence {
        let pipeParts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let targetPart = String(pipeParts[0])
        let alias = pipeParts.count > 1 ? nonEmpty(String(pipeParts[1])) : nil

        let hashParts = targetPart.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pagePath = hashParts[0].trimmingCharacters(in: .whitespaces)
        let heading = hashParts.count > 1 ? nonEmpty(String(hashParts[1])) : nil

        let normalizedPath = normalize(path: pagePath)
        return WikilinkOccurrence(
            kind: kind, pagePath: pagePath, heading: heading, alias: alias,
            normalizedPath: normalizedPath, normalizedStem: stem(ofNormalizedPath: normalizedPath), range: range
        )
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Lowercases and strips a leading `./` and trailing `.md`, so
    /// `"Folder/Page.md"`, `"folder/page"`, and `"./Folder/Page.md"` all
    /// normalize to the same resolution key.
    nonisolated static func normalize(path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespaces)
        while value.hasPrefix("./") { value.removeFirst(2) }
        if value.lowercased().hasSuffix(".md") { value.removeLast(3) }
        return value.lowercased()
    }

    nonisolated static func stem(ofNormalizedPath normalizedPath: String) -> String {
        guard let slash = normalizedPath.lastIndex(of: "/") else { return normalizedPath }
        return String(normalizedPath[normalizedPath.index(after: slash)...])
    }
}
