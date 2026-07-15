import Foundation
import Testing
@testable import SwiftClaw

struct DiffEngineTests {
    @Test func emptyToEmptyProducesNoLines() {
        #expect(DiffEngine.diff(from: "", to: "").isEmpty)
    }

    @Test func identicalTextProducesOnlyUnchangedLines() {
        let text = "one\ntwo\nthree"
        let lines = DiffEngine.diff(from: text, to: text)

        #expect(lines.map(\.content) == ["one", "two", "three"])
        #expect(lines.allSatisfy { $0.kind == .unchanged })
    }

    @Test func pureInsertionMarksEveryLineAdded() {
        let lines = DiffEngine.diff(from: "", to: "one\ntwo")

        #expect(lines.map(\.content) == ["one", "two"])
        #expect(lines.allSatisfy { $0.kind == .added })
    }

    @Test func pureDeletionMarksEveryLineRemoved() {
        let lines = DiffEngine.diff(from: "one\ntwo", to: "")

        #expect(lines.map(\.content) == ["one", "two"])
        #expect(lines.allSatisfy { $0.kind == .removed })
    }

    @Test func middleLineInsertionKeepsSurroundingLinesUnchanged() {
        let lines = DiffEngine.diff(from: "A\nC", to: "A\nB\nC")

        #expect(lines.count == 3)
        #expect(lines[0].kind == .unchanged && lines[0].content == "A")
        #expect(lines[1].kind == .added && lines[1].content == "B")
        #expect(lines[2].kind == .unchanged && lines[2].content == "C")
    }

    @Test func middleLineDeletionKeepsSurroundingLinesUnchanged() {
        let lines = DiffEngine.diff(from: "A\nB\nC", to: "A\nC")

        #expect(lines.count == 3)
        #expect(lines[0].kind == .unchanged && lines[0].content == "A")
        #expect(lines[1].kind == .removed && lines[1].content == "B")
        #expect(lines[2].kind == .unchanged && lines[2].content == "C")
    }

    @Test func replacedLineProducesRemovedThenAdded() {
        let lines = DiffEngine.diff(from: "A\nB\nC", to: "A\nX\nC")

        #expect(lines.map { ($0.kind, $0.content) }.count == 4)
        #expect(lines[0].kind == .unchanged && lines[0].content == "A")
        #expect(lines[1].kind == .removed && lines[1].content == "B")
        #expect(lines[2].kind == .added && lines[2].content == "X")
        #expect(lines[3].kind == .unchanged && lines[3].content == "C")
    }

    @Test func reconstructingAddedAndUnchangedLinesReproducesTheNewText() {
        let newText = "A\nB\nC\nD"
        let lines = DiffEngine.diff(from: "A\nC", to: newText)
        let reconstructed = lines
            .filter { $0.kind != .removed }
            .map(\.content)
            .joined(separator: "\n")

        #expect(reconstructed == newText)
    }

    @Test func reconstructingRemovedAndUnchangedLinesReproducesTheOldText() {
        let oldText = "A\nB\nC\nD"
        let lines = DiffEngine.diff(from: oldText, to: "A\nC")
        let reconstructed = lines
            .filter { $0.kind != .added }
            .map(\.content)
            .joined(separator: "\n")

        #expect(reconstructed == oldText)
    }
}
