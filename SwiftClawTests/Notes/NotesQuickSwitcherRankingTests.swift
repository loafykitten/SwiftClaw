import Foundation
import Testing
@testable import SwiftClaw

@Suite
struct NotesQuickSwitcherRankingTests {
    private func note(_ title: String, path: String? = nil) -> NoteSummary {
        NoteSummary(relativePath: path ?? "\(title).md", title: title, sha256: "h", modifiedAt: .now)
    }

    @Test func emptyQueryListsEveryNoteAlphabetically() {
        let notes = [note("Zebra"), note("Alpha"), note("Mango")]
        let results = NotesQuickSwitcherRanking.rank(query: "", notes: notes)
        #expect(results.map(\.note.title) == ["Alpha", "Mango", "Zebra"])
    }

    @Test func nonEmptyQueryOrdersBestFuzzyMatchFirst() {
        // "Proj" is a consecutive-run prefix match on "Project Plan" (higher
        // score) vs. a scattered subsequence match on "Personal Journal".
        let notes = [note("Personal Journal"), note("Project Plan")]
        let results = NotesQuickSwitcherRanking.rank(query: "Proj", notes: notes)
        #expect(results.first?.note.title == "Project Plan")
    }

    @Test func nonMatchingNotesAreExcluded() {
        let notes = [note("Alpha"), note("Beta")]
        let results = NotesQuickSwitcherRanking.rank(query: "xyz", notes: notes)
        #expect(results.isEmpty)
    }

    @Test func tiedScoresBreakByTitleAlphabetically() {
        // "Cat" and "Bat" are both 3-character titles that match "at" as the
        // same consecutive run at the same offset, so `FuzzyMatcher` scores
        // them identically — the tie must still resolve deterministically.
        let notes = [note("Cat", path: "c.md"), note("Bat", path: "b.md")]
        let results = NotesQuickSwitcherRanking.rank(query: "at", notes: notes)
        #expect(results.count == 2)
        #expect(results[0].match?.score == results[1].match?.score)
        #expect(results.map(\.note.title) == ["Bat", "Cat"])
    }
}
