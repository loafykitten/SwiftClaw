import Foundation

/// A single line in a diff result, tagged with how it relates to the base
/// text. Presentation-only: content is preserved verbatim per line (no
/// trailing newline), suitable for driving a current-vs-proposed UI.
nonisolated struct DiffLine: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case unchanged
        case added
        case removed
    }

    let id: Int
    let kind: Kind
    let content: String
}

/// Deterministic line-level diff (Myers' O(ND) algorithm) between two texts,
/// split on `"\n"`. Shared outside `Notes` (cross-feature: a future
/// email-draft proposal card reuses it unchanged) — pure and dependency-free.
nonisolated enum DiffEngine {
    static func diff(from oldText: String, to newText: String) -> [DiffLine] {
        let oldLines = lines(of: oldText)
        let newLines = lines(of: newText)
        return script(oldLines, newLines).enumerated().map { index, op in
            DiffLine(id: index, kind: op.kind, content: op.content)
        }
    }

    private static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: "\n")
    }

    private struct Operation {
        let kind: DiffLine.Kind
        let content: String
    }

    /// Standard Myers diff: a forward trace building `v[k]` = the furthest
    /// x-coordinate reachable on diagonal `k` at edit distance `d`, followed
    /// by a backtrack through the recorded traces to recover the edit script
    /// in original order.
    private static func script(_ a: [String], _ b: [String]) -> [Operation] {
        let n = a.count
        let m = b.count
        if n == 0 && m == 0 { return [] }
        if n == 0 { return b.map { Operation(kind: .added, content: $0) } }
        if m == 0 { return a.map { Operation(kind: .removed, content: $0) } }

        let maxD = n + m
        let offset = maxD
        var trace: [[Int]] = []
        var v = [Int](repeating: 0, count: 2 * maxD + 1)

        findMiddle: for d in 0...maxD {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m {
                    break findMiddle
                }
            }
        }

        var ops: [Operation] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? k + 1 : k - 1
            let prevX = v[offset + prevK]
            let prevY = prevX - prevK

            while x > prevX && y > prevY {
                ops.append(Operation(kind: .unchanged, content: a[x - 1]))
                x -= 1
                y -= 1
            }

            if d > 0 {
                if x == prevX {
                    ops.append(Operation(kind: .added, content: b[y - 1]))
                } else {
                    ops.append(Operation(kind: .removed, content: a[x - 1]))
                }
            }
            x = prevX
            y = prevY
        }

        return ops.reversed()
    }
}
