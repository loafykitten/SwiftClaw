import Foundation
import Testing
@testable import SwiftClaw

@Suite
struct WikilinkCompletionTests {
    @Test func selectionResetsToTheFirstCandidateOrNil() {
        #expect(WikilinkCompletionSelection.reset(candidateCount: 3) == 0)
        #expect(WikilinkCompletionSelection.reset(candidateCount: 0) == nil)
    }

    @Test func selectionArrowMovementIsBoundedAndRepairsStaleIndices() {
        #expect(WikilinkCompletionSelection.move(.down, from: 0, candidateCount: 3) == 1)
        #expect(WikilinkCompletionSelection.move(.down, from: 2, candidateCount: 3) == 2)
        #expect(WikilinkCompletionSelection.move(.up, from: 1, candidateCount: 3) == 0)
        #expect(WikilinkCompletionSelection.move(.up, from: 0, candidateCount: 3) == 0)
        #expect(WikilinkCompletionSelection.move(.down, from: nil, candidateCount: 3) == 0)
        #expect(WikilinkCompletionSelection.move(.down, from: 9, candidateCount: 3) == 0)
        #expect(WikilinkCompletionSelection.move(.down, from: 0, candidateCount: 0) == nil)
    }

    @Test func utf16CursorOffsetCountsEmojiBeforeTheCursor() {
        let prefix = "🙂 See [[Auto"
        let text = prefix + "]]"
        let cursor = text.index(text.startIndex, offsetBy: prefix.count)

        #expect(WikilinkCompletion.utf16Offset(for: cursor, in: text) == (prefix as NSString).length)
    }

    @Test func triggersRightAfterAnOpenBracketPair() {
        let text = "See [[Pl"
        let trigger = WikilinkCompletion.trigger(in: text, cursorLocation: (text as NSString).length)
        #expect(trigger?.query == "Pl")
    }

    @Test func triggerSearchIsScopedToTheCurrentLine() {
        let previousLineOnly = "[[Previous\nPlain text"
        #expect(
            WikilinkCompletion.trigger(
                in: previousLineOnly,
                cursorLocation: (previousLineOnly as NSString).length
            ) == nil
        )

        let currentLine = "[[Previous\nPlain [[Current"
        let trigger = WikilinkCompletion.trigger(in: currentLine, cursorLocation: (currentLine as NSString).length)
        #expect(trigger?.query == "Current")
        #expect(trigger?.queryRange.location == ("[[Previous\nPlain [[" as NSString).length)
    }

    @Test func doesNotTriggerWithoutAnOpenBracketPair() {
        let text = "Just plain text"
        #expect(WikilinkCompletion.trigger(in: text, cursorLocation: (text as NSString).length) == nil)
    }

    @Test func doesNotTriggerOnceTheLinkIsClosed() {
        let text = "See [[Place]] and more"
        #expect(WikilinkCompletion.trigger(in: text, cursorLocation: (text as NSString).length) == nil)
    }

    @Test func doesNotTriggerAfterAPipeOrHashOrNewline() {
        let pipeText = "[[Page|Alias" as NSString
        #expect(WikilinkCompletion.trigger(in: pipeText as String, cursorLocation: pipeText.length) == nil)

        let hashText = "[[Page#Heading" as NSString
        #expect(WikilinkCompletion.trigger(in: hashText as String, cursorLocation: hashText.length) == nil)

        let newlineText = "[[Page\nMore" as NSString
        #expect(WikilinkCompletion.trigger(in: newlineText as String, cursorLocation: newlineText.length) == nil)
    }

    @Test func doesNotTriggerBeforeAnAliasHeadingOrNewlineBoundary() {
        let pipeText = "[[Pa|Alias]]"
        #expect(WikilinkCompletion.trigger(in: pipeText, cursorLocation: ("[[Pa" as NSString).length) == nil)

        let hashText = "[[Pa#Heading]]"
        #expect(WikilinkCompletion.trigger(in: hashText, cursorLocation: ("[[Pa" as NSString).length) == nil)

        let newlineText = "[[Pa\nMore]]"
        #expect(WikilinkCompletion.trigger(in: newlineText, cursorLocation: ("[[Pa" as NSString).length) == nil)
    }

    @Test func doesNotTriggerInTheMiddleOfAnAlreadyClosedTarget() {
        let text = "See [[Auto]]"
        let cursorLocation = ("See [[Au" as NSString).length

        #expect(WikilinkCompletion.trigger(in: text, cursorLocation: cursorLocation) == nil)
    }

    @Test func triggerDetectsClosingBracketsImmediatelyAfterTheCursor() {
        let text = "See [[Auto]]"
        let cursorLocation = ("See [[Auto" as NSString).length

        let trigger = WikilinkCompletion.trigger(in: text, cursorLocation: cursorLocation)

        #expect(trigger?.query == "Auto")
        #expect(trigger?.hasTrailingClosingBrackets == true)
    }

    @Test func rankedCandidatesFuzzyMatchesAgainstTitleAndExcludesTheCurrentNote() {
        let notes = [
            NoteSummary(relativePath: "Planet.md", title: "Planet", sha256: "a", modifiedAt: .now),
            NoteSummary(relativePath: "Plan.md", title: "Plan", sha256: "b", modifiedAt: .now),
            NoteSummary(relativePath: "Other.md", title: "Other", sha256: "c", modifiedAt: .now),
        ]
        let candidates = WikilinkCompletion.rankedCandidates(query: "Pl", notes: notes, excluding: "Plan.md")
        #expect(candidates.map(\.note.relativePath) == ["Planet.md"])
    }

    @Test func rankedCandidatesWithEmptyQueryListsEveryoneAlphabeticallyExceptExcluded() {
        let notes = [
            NoteSummary(relativePath: "B.md", title: "Bravo", sha256: "a", modifiedAt: .now),
            NoteSummary(relativePath: "A.md", title: "Alpha", sha256: "b", modifiedAt: .now),
        ]
        let candidates = WikilinkCompletion.rankedCandidates(query: "", notes: notes, excluding: nil)
        #expect(candidates.map(\.note.title) == ["Alpha", "Bravo"])
    }

    @Test func completionTextStripsTheMarkdownExtensionAndClosesTheLink() {
        let note = NoteSummary(relativePath: "Folder/Page.md", title: "Page", sha256: "a", modifiedAt: .now)
        #expect(WikilinkCompletion.completionText(for: note) == "Folder/Page]]")
    }

    @Test func completionTextHandlesUnicodeTitlesAndPaths() {
        let note = NoteSummary(relativePath: "日記/Café Notes.md", title: "Café Notes", sha256: "a", modifiedAt: .now)
        #expect(WikilinkCompletion.completionText(for: note) == "日記/Café Notes]]")
    }

    @Test func completionTextReusesAnExistingClosingPair() {
        let note = NoteSummary(relativePath: "Folder/Page.md", title: "Page", sha256: "a", modifiedAt: .now)

        #expect(
            WikilinkCompletion.completionText(for: note, closingBracketsAlreadyPresent: true)
                == "Folder/Page"
        )
    }

    /// Regression: acceptance must produce a fully closed `[[...]]` link, and
    /// applying that replacement (as `WikilinkCompletionOverlay.accept(_:)`
    /// does via `NoteEditorController.applyReplacement`) must land the cursor
    /// somewhere `trigger(in:cursorLocation:)` no longer detects an unclosed
    /// `[[` — otherwise the very next `textDidChange`/selection-change
    /// notification the insertion itself triggers reopens the popup it was
    /// just dismissed from.
    @Test func acceptedCompletionClosesTheLinkAndDoesNotReopenTheTrigger() {
        let note = NoteSummary(relativePath: "Autocomplete Candidate.md", title: "Autocomplete Candidate", sha256: "a", modifiedAt: .now)
        let typed = "See [[Auto"
        let trigger = try! #require(WikilinkCompletion.trigger(in: typed, cursorLocation: (typed as NSString).length))
        let replacement = WikilinkCompletion.completionText(for: note)

        let nsText = typed as NSString
        let finalText = nsText.replacingCharacters(in: trigger.queryRange, with: replacement)
        let cursorAfterInsert = trigger.queryRange.location + (replacement as NSString).length

        #expect(finalText == "See [[Autocomplete Candidate]]")
        #expect(WikilinkCompletion.trigger(in: finalText, cursorLocation: cursorAfterInsert) == nil)
    }
}
