import Foundation
import os
import SwiftData

typealias NotesReviewInferenceComplete = @Sendable ([InferenceMessage], String, InferenceSystemPromptMode, [any Tool]) async throws -> String

@MainActor
final class NotesReviewService {
    private static let logger = AppLog.make("notes.review")
    private let modelContainer: ModelContainer
    private let userDefaults: UserDefaults

    /// Memory availability through this service's injected defaults — the
    /// global `MemoryFeatureModel.shared.isAvailable` reads `.standard`,
    /// which tests must not depend on.
    private var isMemoryAvailable: Bool {
        SettingsStorage.isMemoryEnabled(userDefaults: userDefaults)
            && MemoryFeatureModel.shared.repository != nil
    }
    private let dataSource: any NotesReviewDataSource
    var onReviewCreated: ((UUID, String) -> Void)?
    private(set) var lastStatusMessage: String?

    var completeProvider: NotesReviewInferenceComplete = { messages, model, mode, tools in
        try await InferenceService.shared.complete(messages: messages, model: model, systemPromptMode: mode, tools: tools)
    }

    var unreadChatIDsProvider: () -> Set<UUID> = { AppRouter.shared.unreadChatIDs }

    init(modelContainer: ModelContainer, userDefaults: UserDefaults = .standard, dataSource: any NotesReviewDataSource = NotesFeatureReviewDataSource()) {
        self.modelContainer = modelContainer
        self.userDefaults = userDefaults
        self.dataSource = dataSource
    }

    @discardableResult
    func runOnce(force: Bool = false, targetChatID: UUID? = nil) async -> Bool {
        lastStatusMessage = nil
        guard !ProcessInfo.processInfo.isRunningInPreview else { lastStatusMessage = "Review skipped in previews"; return false }
        if !force, hasUnreadReviewChat() {
            lastStatusMessage = "Previous review is still unread"; return false
        }

        await dataSource.prepare()
        guard dataSource.isAvailable else { lastStatusMessage = "Notes is unavailable"; return false }
        #if DEBUG
            let usesFixtureInference = NotesPhaseSixFixture.isEnabled()
        #else
            let usesFixtureInference = false
        #endif
        let model = SettingsStorage.loadModelSelection(forKey: SettingsKeys.clawModel, userDefaults: userDefaults)
        guard usesFixtureInference || !model.isEmpty else { lastStatusMessage = "Review needs a model in Settings"; return false }

        let collector = NotesReviewFindingCollector()
        let memoryCollector = MemoryProposalRunCollector()
        let reviewChatCapture = MemoryReviewChatCapture()
        let fetch = NotesReviewFetchTool(dataSource: dataSource, collector: collector, userDefaults: userDefaults)
        let notify = NotesReviewNotifyTool(modelContainer: modelContainer, collector: collector, targetChatID: targetChatID) { [weak self] chatID, summary in
            reviewChatCapture.chatID = chatID
            if targetChatID == nil {
                self?.onReviewCreated?(chatID, summary)
            }
        }
        var reviewTools: [any Tool] = [fetch, notify]
        if isMemoryAvailable {
            reviewTools.append(ProposeMemoryTool(
                feature: .notes,
                modelContainer: modelContainer,
                collector: memoryCollector
            ))
        }
        let tools = ToolRegistry(tools: reviewTools).availableTools
        var systemPrompt = Self.systemPrompt(userDefaults: userDefaults)
        if let memoryBlock = MemoryReviewContextBuilder.block(for: .notes, isEnabled: isMemoryAvailable) {
            systemPrompt += "\n\n\(memoryBlock)"
        }
        let messages: [InferenceMessage] = [.system(systemPrompt), .user(Self.userPrompt())]
        do {
            #if DEBUG
                if usesFixtureInference {
                    try await NotesPhaseSixFixture.run(fetchTool: fetch, notifyTool: notify)
                } else {
                    _ = try await completeProvider(messages, model, .standalone, tools)
                }
            #else
                _ = try await completeProvider(messages, model, .standalone, tools)
            #endif
        } catch {
            Self.logger.error("Notes review inference failed: \(String(describing: error))")
            lastStatusMessage = "Review failed"
            return false
        }
        // Any memory proposals this run raised get their cards now — into
        // the run's review chat when one exists, else the shared
        // "Memory suggestions" chat. The router also sweeps this source's
        // orphans from runs that were interrupted before routing.
        MemoryReviewProposalRouter.route(
            proposalIDs: memoryCollector.proposalIDs,
            for: .notes,
            preferredChatID: targetChatID ?? reviewChatCapture.chatID,
            modelContainer: modelContainer
        )
        // Completion is recorded only after inference returns successfully;
        // failures remain eligible for retry.
        SettingsStorage.saveNotesLastReviewCompletedAt(.now, userDefaults: userDefaults)
        lastStatusMessage = "Review complete"
        return true
    }

    private func hasUnreadReviewChat() -> Bool {
        let ids = Array(unreadChatIDsProvider())
        guard !ids.isEmpty else { return false }
        let descriptor = FetchDescriptor<Chat>(predicate: #Predicate { ids.contains($0.id) })
        guard let chats = try? modelContainer.mainContext.fetch(descriptor) else { return false }
        return chats.contains { !$0.isArchived && $0.isNotesReviewChat }
    }

    private static func systemPrompt(userDefaults: UserDefaults) -> String {
        """
        \(AssistantPersona.personaPrompt(userDefaults: userDefaults))

        Review Notes as a read-only vault-hygiene and triage assistant. FIRST call `fetch_notes_review_digest`. Look only for unchecked daily-note tasks, conflict copies, broken links, recent-note follow-up, and index health. Quality over quantity.

        Never edit notes, propose edits, reorganize content, or turn this into writing advice. The finding UUIDs are temporary IDs for this pass, not note paths or durable identities.

        If something genuinely needs attention, call `notify_user_about_notes` once with:
        {"findings":[{"finding_id":"<exact fetched UUID>","summary":"<specific triage reason>"}],"message":"<short summary>"}
        Copy UUIDs exactly. If nothing needs attention, do not notify.
        """
    }

    private static func userPrompt() -> String {
        "Review my Notes vault for hygiene and triage only. Fetch the digest first and surface only actionable findings."
    }
}
