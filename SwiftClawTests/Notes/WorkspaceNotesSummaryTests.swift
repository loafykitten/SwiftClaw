import Foundation
@testable import SwiftClaw
import Testing

struct WorkspaceNotesSummaryTests {
    private func health(
        brokenLinks: Int = 0,
        conflicts: Int = 0,
        ftsAvailable: Bool = true,
        failedPaths: [String] = [],
        error: String? = nil
    ) -> NotesHealthSummary {
        NotesHealthSummary(
            brokenLinkCount: brokenLinks,
            conflictCopyCount: conflicts,
            ftsAvailable: ftsAvailable,
            embeddingAvailable: false,
            lastIndexSuccessAt: nil,
            lastIndexFailedPaths: failedPaths,
            indexError: error
        )
    }

    @Test func reportsCountsAndHealthyState() {
        let notes = [
            NoteSummary(relativePath: "A.md", title: "A", sha256: "1", modifiedAt: .now),
            NoteSummary(relativePath: "B.md", title: "B", sha256: "2", modifiedAt: .now),
        ]
        let summary = WorkspaceNotesSummary(notes: notes, capturedTodayCount: 3, healthSummary: health())

        #expect(summary.noteCount == 2)
        #expect(summary.capturedTodayCount == 3)
        #expect(summary.health == .healthy)
    }

    @Test func actionableVaultProblemsAreWarnings() {
        #expect(WorkspaceNotesSummary(notes: [], capturedTodayCount: 0, healthSummary: health(brokenLinks: 1)).health == .warning)
        #expect(WorkspaceNotesSummary(notes: [], capturedTodayCount: 0, healthSummary: health(conflicts: 1)).health == .warning)
        #expect(WorkspaceNotesSummary(notes: [], capturedTodayCount: 0, healthSummary: health(failedPaths: ["Bad.md"])).health == .warning)
    }

    @Test func missingHealthIsUnavailableAndReportedIndexProblemsWarn() {
        #expect(WorkspaceNotesSummary(notes: [], capturedTodayCount: 0, healthSummary: nil).health == .unavailable)
        #expect(WorkspaceNotesSummary(notes: [], capturedTodayCount: 0, healthSummary: health(ftsAvailable: false)).health == .warning)
        #expect(WorkspaceNotesSummary(notes: [], capturedTodayCount: 0, healthSummary: health(error: "disk full")).health == .warning)
    }
}
