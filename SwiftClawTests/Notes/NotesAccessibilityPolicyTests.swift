import Testing
@testable import SwiftClaw

@Suite
struct NotesAccessibilityPolicyTests {
    @Test func quickSwitcherSelectionStaysValidAsResultsChange() {
        #expect(NotesQuickSwitcherSelection.validSelection("b.md", in: ["a.md", "b.md"]) == "b.md")
        #expect(NotesQuickSwitcherSelection.validSelection("missing.md", in: ["a.md", "b.md"]) == "a.md")
        #expect(NotesQuickSwitcherSelection.validSelection("missing.md", in: []) == nil)
    }

    @Test func quickSwitcherArrowMovementIsBoundedAndSafe() {
        let paths = ["a.md", "b.md", "c.md"]
        #expect(NotesQuickSwitcherSelection.move(.down, from: "a.md", in: paths) == "b.md")
        #expect(NotesQuickSwitcherSelection.move(.down, from: "c.md", in: paths) == "c.md")
        #expect(NotesQuickSwitcherSelection.move(.up, from: "b.md", in: paths) == "a.md")
        #expect(NotesQuickSwitcherSelection.move(.up, from: "a.md", in: paths) == "a.md")
        #expect(NotesQuickSwitcherSelection.move(.down, from: nil, in: paths) == "a.md")
        #expect(NotesQuickSwitcherSelection.move(.down, from: nil, in: []) == nil)
    }

    @Test func blankDiffLinesHaveClearSpokenLabels() {
        #expect(NoteProposalDiffAccessibility.label(for: DiffLine(id: 0, kind: .added, content: "")) == "Blank line added")
        #expect(NoteProposalDiffAccessibility.label(for: DiffLine(id: 1, kind: .removed, content: "   ")) == "Blank line removed")
        #expect(NoteProposalDiffAccessibility.label(for: DiffLine(id: 2, kind: .unchanged, content: "")) == "Blank line unchanged")
    }
}
