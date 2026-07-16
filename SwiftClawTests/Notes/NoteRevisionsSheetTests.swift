import Testing
@testable import SwiftClaw

@Suite
struct NoteRevisionsSheetTests {
    @Test func previewSkipsLeadingFrontMatterAndBlankLines() {
        let content = """
        ---
        title: Same metadata
        tags: [notes]
        ---


        Revision-specific body
        """

        #expect(NoteRevisionsSheet.preview(for: content) == "Revision-specific body")
    }

    @Test func previewWithoutFrontMatterKeepsExistingBehavior() {
        #expect(NoteRevisionsSheet.preview(for: "\n  Body text  \n") == "Body text")
    }

    @Test func previewUsesEmptyNoteFallbackAfterFrontMatter() {
        let content = """
        ---
        title: Metadata only
        ---

        """

        #expect(NoteRevisionsSheet.preview(for: content) == "Empty note")
        #expect(NoteRevisionsSheet.preview(for: " \n\t") == "Empty note")
    }
}
