import Foundation
import Testing
@testable import SwiftClaw

@Suite
struct NotesHealthPresentationTests {
    private func healthySummary() -> NotesHealthSummary {
        NotesHealthSummary(
            brokenLinkCount: 0, conflictCopyCount: 0, ftsAvailable: true, embeddingAvailable: true,
            lastIndexSuccessAt: .now, lastIndexFailedPaths: [], indexError: nil
        )
    }

    @Test func healthySummaryProducesNoBanner() {
        #expect(NotesHealthPresentation.banner(for: healthySummary()) == nil)
    }

    @Test func embeddingsIntentionallyDisabledIsNotTreatedAsAProblem() {
        var summary = healthySummary()
        summary = NotesHealthSummary(
            brokenLinkCount: 0, conflictCopyCount: 0, ftsAvailable: true, embeddingAvailable: false,
            lastIndexSuccessAt: summary.lastIndexSuccessAt, lastIndexFailedPaths: [], indexError: nil
        )
        #expect(NotesHealthPresentation.banner(for: summary) == nil)
    }

    @Test func brokenLinksSurfaceWithSingularAndPluralWording() {
        let one = NotesHealthSummary(
            brokenLinkCount: 1, conflictCopyCount: 0, ftsAvailable: true, embeddingAvailable: true,
            lastIndexSuccessAt: nil, lastIndexFailedPaths: [], indexError: nil
        )
        #expect(NotesHealthPresentation.banner(for: one)?.message == "1 broken link")
        #expect(NotesHealthPresentation.banner(for: one)?.hasBrokenLinks == true)

        let many = NotesHealthSummary(
            brokenLinkCount: 3, conflictCopyCount: 0, ftsAvailable: true, embeddingAvailable: true,
            lastIndexSuccessAt: nil, lastIndexFailedPaths: [], indexError: nil
        )
        #expect(NotesHealthPresentation.banner(for: many)?.message == "3 broken links")
    }

    @Test func multipleProblemsAreJoinedTogether() {
        let summary = NotesHealthSummary(
            brokenLinkCount: 2, conflictCopyCount: 1, ftsAvailable: false, embeddingAvailable: true,
            lastIndexSuccessAt: nil, lastIndexFailedPaths: ["Bad.md"], indexError: "disk full"
        )
        let banner = NotesHealthPresentation.banner(for: summary)
        #expect(banner?.message == "2 broken links · 1 conflict copy · 1 note failed to index · full-text search unavailable · disk full")
        #expect(banner?.hasBrokenLinks == true)
    }

    @Test func failedIndexPathsAloneStillProduceABanner() {
        let summary = NotesHealthSummary(
            brokenLinkCount: 0, conflictCopyCount: 0, ftsAvailable: true, embeddingAvailable: true,
            lastIndexSuccessAt: nil, lastIndexFailedPaths: ["A.md", "B.md"], indexError: nil
        )
        #expect(NotesHealthPresentation.banner(for: summary)?.message == "2 notes failed to index")
        #expect(NotesHealthPresentation.banner(for: summary)?.hasBrokenLinks == false)
    }
}
