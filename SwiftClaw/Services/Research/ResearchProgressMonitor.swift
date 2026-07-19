import Foundation
import Observation

@MainActor
@Observable
final class ResearchProgressMonitor {
    static let shared = ResearchProgressMonitor()

    var activeSessionID: UUID?
    var stage: ResearchStage?
    var activityFeed: [String] = []
    var sourceCount = 0
    var startedAt: Date?
    var budgetDuration: Duration?
    var isRunning = false

    func begin(sessionID: UUID, budget: Duration) {
        activeSessionID = sessionID
        stage = nil
        activityFeed = []
        sourceCount = 0
        startedAt = .now
        budgetDuration = budget
        isRunning = true
    }

    func apply(_ event: ResearchProgressEvent) {
        switch event {
        case let .stageChanged(stage):
            self.stage = stage
        case let .activity(line):
            activityFeed.append(line)
            if activityFeed.count > 20 {
                activityFeed.removeFirst(activityFeed.count - 20)
            }
        case let .sourceCount(count):
            sourceCount = count
        }
    }

    func finish() {
        activeSessionID = nil
        stage = nil
        startedAt = nil
        budgetDuration = nil
        isRunning = false
    }
}
