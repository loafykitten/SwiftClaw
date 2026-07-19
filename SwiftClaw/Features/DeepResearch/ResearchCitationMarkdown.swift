import Foundation

/// Rewrites `[n]` citation markers in a research report into same-app
/// citation links, without corrupting markdown structure: fenced code,
/// inline code, and existing `[label](url)` links pass through untouched.
enum ResearchCitationMarkdown {
    /// Also derives which sources back a ⚠-flagged claim: any citation index
    /// in the same *sentence* as the marker. Paragraphs are single markdown
    /// lines, so line granularity would smear one flagged claim over every
    /// verified citation in the paragraph.
    struct Rendering {
        let markdown: String
        let flaggedSourceIndices: Set<Int>
    }

    static func linkingCitations(in report: String, validIndices: Set<Int>) -> Rendering {
        guard !validIndices.isEmpty else {
            return Rendering(markdown: report, flaggedSourceIndices: [])
        }

        var output = ""
        output.reserveCapacity(report.count + 256)
        var flagged = Set<Int>()
        var isInFence = false

        for (index, rawLine) in report.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                output += "\n"
            }
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInFence.toggle()
                output += line
                continue
            }
            if isInFence {
                output += line
                continue
            }

            let converted = convertLine(line, validIndices: validIndices)
            output += converted
            if line.contains("⚠") {
                for sentence in sentences(in: line) where sentence.contains("⚠") {
                    flagged.formUnion(
                        citationIndices(in: String(sentence), validIndices: validIndices)
                    )
                }
            }
        }

        return Rendering(markdown: output, flaggedSourceIndices: flagged)
    }

    /// One line at a time: walks characters, skipping inline code spans and
    /// leaving `[n](...)` (an existing link) alone.
    private static func convertLine(_ line: String, validIndices: Set<Int>) -> String {
        var output = ""
        output.reserveCapacity(line.count + 32)
        var remainder = Substring(line)
        var isInCodeSpan = false

        while let next = remainder.first {
            if next == "`" {
                isInCodeSpan.toggle()
                output.append(next)
                remainder = remainder.dropFirst()
                continue
            }
            guard next == "[", !isInCodeSpan else {
                output.append(next)
                remainder = remainder.dropFirst()
                continue
            }

            let afterOpen = remainder.index(after: remainder.startIndex)
            guard let close = remainder[afterOpen...].firstIndex(of: "]"),
                  let index = Int(remainder[afterOpen..<close]),
                  validIndices.contains(index),
                  // "[3](https://…)" is already a link — leave it intact.
                  remainder[remainder.index(after: close)...].first != "(",
                  let url = MarkdownInlineRenderer.citationURL(forSourceIndex: index) else {
                output.append(next)
                remainder = remainder.dropFirst()
                continue
            }

            output += "[\\[\(index)\\]](\(url.absoluteString))"
            remainder = remainder[remainder.index(after: close)...]
        }

        return output
    }

    /// Splits a line on sentence terminators (`.` `!` `?` followed by a
    /// space or end of line). The ⚠ marker precedes its sentence's closing
    /// period ("… BCE [2] ⚠."), so it stays inside the right segment.
    private static func sentences(in line: String) -> [Substring] {
        var result = [Substring]()
        var start = line.startIndex
        var index = line.startIndex
        while index < line.endIndex {
            let next = line.index(after: index)
            if ".!?".contains(line[index]), next == line.endIndex || line[next] == " " {
                result.append(line[start..<next])
                start = next
            }
            index = next
        }
        if start < line.endIndex {
            result.append(line[start...])
        }
        return result
    }

    private static func citationIndices(in line: String, validIndices: Set<Int>) -> Set<Int> {
        var found = Set<Int>()
        var remainder = Substring(line)
        while let open = remainder.firstIndex(of: "[") {
            let afterOpen = remainder.index(after: open)
            guard let close = remainder[afterOpen...].firstIndex(of: "]") else { break }
            if let index = Int(remainder[afterOpen..<close]), validIndices.contains(index) {
                found.insert(index)
            }
            remainder = remainder[remainder.index(after: close)...]
        }
        return found
    }
}
