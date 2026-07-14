import Testing
@testable import SwiftClaw

@Suite
struct NotesCompactNavigationTests {
    @Test func quickSwitcherRoutesToADifferentNoteAfterSelection() {
        #expect(
            NotesCompactNavigation.destination(
                for: "Sources/Beta.md",
                selectedPath: "Sources/Beta.md",
                currentDetailPath: "Sources/Alpha.md"
            ) == "Sources/Beta.md"
        )
    }

    @Test func doesNotNavigateWhenSelectionFailsOrChanges() {
        #expect(
            NotesCompactNavigation.destination(
                for: "Projects/Plan.md",
                selectedPath: nil,
                currentDetailPath: nil
            ) == nil
        )
        #expect(
            NotesCompactNavigation.destination(
                for: "Projects/Plan.md",
                selectedPath: "Inbox/Other.md",
                currentDetailPath: nil
            ) == nil
        )
    }

    @Test func quickSwitcherDoesNotPushTheNoteAlreadyDisplayed() {
        #expect(
            NotesCompactNavigation.destination(
                for: "Sources/Beta.md",
                selectedPath: "Sources/Beta.md",
                currentDetailPath: "Sources/Beta.md"
            ) == nil
        )
    }

    @Test func compactDetailReportsFailureAfterARejectedSelection() {
        #expect(
            NotesCompactDetailSelectionState.afterSelection(
                requestedPath: "Projects/Plan.md",
                selectedPath: "Inbox/Unsaved.md",
                editorSelectedPath: "Inbox/Unsaved.md"
            ) == .failed
        )
    }

    @Test func compactDetailReportsSuccessOnlyWhenModelAndEditorMatchTheRequest() {
        #expect(
            NotesCompactDetailSelectionState.afterSelection(
                requestedPath: "Projects/Plan.md",
                selectedPath: "Projects/Plan.md",
                editorSelectedPath: "Projects/Plan.md"
            ) == .selected
        )
    }
}
