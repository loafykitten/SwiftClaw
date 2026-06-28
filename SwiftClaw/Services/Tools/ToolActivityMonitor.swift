import Foundation
import Observation

nonisolated struct ToolActivityScope: Hashable, Sendable {
    let chatID: UUID
    let generationID: UUID
}

nonisolated enum ToolActivityContext {
    @TaskLocal static var currentScope: ToolActivityScope?
}

/// Publishes what a long-running tool is currently doing so chat UI can show
/// a specific status (e.g. "Investigating") instead of the default animated
/// ellipsis indicator.
@MainActor
@Observable
final class ToolActivityMonitor {
    static let shared = ToolActivityMonitor()

    private var activeGenerationByChatID = [UUID: UUID]()
    private var statusLabelByScope = [ToolActivityScope: String]()

    func beginGeneration(_ scope: ToolActivityScope) {
        if let previousGenerationID = activeGenerationByChatID[scope.chatID] {
            statusLabelByScope[
                ToolActivityScope(chatID: scope.chatID, generationID: previousGenerationID)
            ] = nil
        }

        activeGenerationByChatID[scope.chatID] = scope.generationID
    }

    func endGeneration(_ scope: ToolActivityScope) {
        statusLabelByScope[scope] = nil

        if activeGenerationByChatID[scope.chatID] == scope.generationID {
            activeGenerationByChatID[scope.chatID] = nil
        }
    }

    func statusLabel(forChatID chatID: UUID) -> String? {
        guard let generationID = activeGenerationByChatID[chatID] else {
            return nil
        }

        return statusLabelByScope[
            ToolActivityScope(chatID: chatID, generationID: generationID)
        ]
    }

    func setStatusLabel(_ label: String?, for scope: ToolActivityScope?) {
        guard let scope else {
            return
        }

        if let label, !label.isEmpty {
            statusLabelByScope[scope] = label
        } else {
            statusLabelByScope[scope] = nil
        }
    }
}
