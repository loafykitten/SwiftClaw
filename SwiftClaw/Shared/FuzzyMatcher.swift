import Foundation

/// A reusable, case-insensitive subsequence matcher for quick-switcher-style
/// UI (Notes' switcher is the first caller; a follow-up app-global Cmd-K
/// switcher can reuse it unchanged per `docs/features/NOTES.md` cross-feature
/// follow-up #4). Pure and dependency-free.
enum FuzzyMatcher {
    struct Match: Sendable, Equatable {
        let score: Double
        let ranges: [Range<String.Index>]
    }

    /// Returns `nil` when `query`'s characters don't all appear, in order,
    /// somewhere in `candidate` (a non-match) — an empty `query` also never
    /// matches. Otherwise scores higher for consecutive runs and for
    /// matches that start earlier in `candidate`.
    static func match(query: String, in candidate: String) -> Match? {
        guard !query.isEmpty, !candidate.isEmpty else { return nil }
        let candidateChars = Array(candidate)
        let queryChars = Array(query)

        var candidateIndex = 0
        var matchedOffsets: [Int] = []
        for queryChar in queryChars {
            var found = false
            while candidateIndex < candidateChars.count {
                defer { candidateIndex += 1 }
                if candidateChars[candidateIndex].lowercased() == queryChar.lowercased() {
                    matchedOffsets.append(candidateIndex)
                    found = true
                    break
                }
            }
            if !found { return nil }
        }

        let ranges = consecutiveRanges(of: matchedOffsets, in: candidate)
        let score = self.score(matchedOffsets: matchedOffsets, ranges: ranges, candidateLength: candidateChars.count)
        return Match(score: score, ranges: ranges)
    }

    private static func score(matchedOffsets: [Int], ranges: [Range<String.Index>], candidateLength: Int) -> Double {
        var total = 0.0
        for (position, offset) in matchedOffsets.enumerated() {
            let isConsecutive = position > 0 && offset == matchedOffsets[position - 1] + 1
            total += isConsecutive ? 3.0 : 1.0
        }
        if let firstOffset = matchedOffsets.first, candidateLength > 0 {
            total += Double(candidateLength - firstOffset) / Double(candidateLength)
        }
        return total
    }

    /// Collapses consecutive character offsets into `String.Index` ranges,
    /// e.g. matched offsets `[0, 1, 3]` in "abcd" become two ranges: `a..<c`
    /// and `d..<end`.
    private static func consecutiveRanges(of offsets: [Int], in candidate: String) -> [Range<String.Index>] {
        guard !offsets.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var runStart = offsets[0]
        var previous = offsets[0]

        func closeRun(at end: Int) {
            let startIndex = candidate.index(candidate.startIndex, offsetBy: runStart)
            let endIndex = candidate.index(candidate.startIndex, offsetBy: end)
            ranges.append(startIndex..<endIndex)
        }

        for offset in offsets.dropFirst() {
            if offset == previous + 1 {
                previous = offset
                continue
            }
            closeRun(at: previous + 1)
            runStart = offset
            previous = offset
        }
        closeRun(at: previous + 1)
        return ranges
    }
}
