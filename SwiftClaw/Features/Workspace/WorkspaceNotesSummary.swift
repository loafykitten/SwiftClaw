import Foundation

/// Pure Notes stats and health classification for the Workspace tile.
nonisolated struct WorkspaceNotesSummary: Equatable {
    enum Health: Equatable {
        case healthy
        case warning
        case unavailable
    }

    let noteCount: Int
    let capturedTodayCount: Int
    let health: Health

    init(notes: [NoteSummary], capturedTodayCount: Int, healthSummary: NotesHealthSummary?) {
        noteCount = notes.count
        self.capturedTodayCount = max(0, capturedTodayCount)

        guard let healthSummary else {
            health = .unavailable
            return
        }
        if healthSummary.brokenLinkCount > 0
            || healthSummary.conflictCopyCount > 0
            || !healthSummary.lastIndexFailedPaths.isEmpty
            || !healthSummary.ftsAvailable
            || healthSummary.indexError != nil
        {
            health = .warning
        } else {
            health = .healthy
        }
    }
}
