import Foundation
import os
import SwiftData

/// Persists read-only summaries for pass-local findings. `ReviewItem.itemID`
/// is an ephemeral validation token; card consumers must not interpret it as
/// a note path or durable note identity.
final class NotesReviewNotifyTool: Tool {
    private static let logger = AppLog.make("notes.review.tool")
    let name = "notify_user_about_notes"
    let displayName = "Notify User About Notes"
    let description = "Creates a Notes hygiene review card from validated finding IDs returned by fetch_notes_review_digest."
    let systemImage = "note.text"
    let parameters = [
        ToolParameter(name: "findings", type: .array, description: "Array of { finding_id, summary } objects using exact fetched IDs.", isRequired: true),
        ToolParameter(name: "message", type: .string, description: "Short triage summary shown above the card.", isRequired: true),
        ToolParameter(name: "notification_summary", type: .string, description: "Plain notification sentence under 20 words."),
    ]
    var isConfigured: Bool {
        true
    }

    var isEnabled: Bool {
        true
    }

    struct Dependencies: Sendable {
        var save: @MainActor @Sendable (ModelContext) throws -> Void = { try $0.save() }
    }

    private struct RequestedFinding: Codable {
        let findingID: String
        let summary: String?
        enum CodingKeys: String, CodingKey { case findingID = "finding_id"; case summary }
    }

    private enum Outcome { case skipped, invalid, failed, created(Int) }

    private let modelContainer: ModelContainer
    private let collector: NotesReviewFindingCollector
    private let targetChatID: UUID?
    private let onReviewCreated: (@MainActor (UUID, String) -> Void)?
    private let dependencies: Dependencies
    @MainActor private var hasPersistedForRun = false

    init(modelContainer: ModelContainer, collector: NotesReviewFindingCollector, targetChatID: UUID? = nil, onReviewCreated: (@MainActor (UUID, String) -> Void)? = nil, dependencies: Dependencies = .init()) {
        self.modelContainer = modelContainer
        self.collector = collector
        self.targetChatID = targetChatID
        self.onReviewCreated = onReviewCreated
        self.dependencies = dependencies
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let raw = arguments["findings"], let message = arguments["message"]?.stringValue else {
            throw ToolError.missingArgument("findings/message")
        }
        let requested: [RequestedFinding]
        do {
            switch raw {
            case .array:
                requested = try JSONDecoder().decode([RequestedFinding].self, from: JSONEncoder().encode(raw))
            case let .string(string):
                guard let data = string.data(using: .utf8) else { throw ToolError.invalidArguments("findings string is not UTF-8") }
                requested = try JSONDecoder().decode([RequestedFinding].self, from: data)
            default: throw ToolError.invalidArguments("findings must be an array or JSON-array string")
            }
        } catch let error as ToolError { throw error }
        catch { throw ToolError.invalidArguments("findings is not a valid array: \(error.localizedDescription)") }

        let resolved = await MainActor.run {
            requested.compactMap { request -> (NotesReviewFindingCollector.Finding, String?)? in
                guard let id = UUID(uuidString: request.findingID), let finding = collector.finding(id: id) else { return nil }
                return (finding, request.summary)
            }
        }
        guard !resolved.isEmpty, resolved.count == requested.count else {
            throw ToolError.invalidArguments("every finding must use a valid ID returned by this review pass")
        }

        let notification = arguments["notification_summary"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome = await MainActor.run { () -> Outcome in
            if hasPersistedForRun {
                return .skipped
            }
            let items = resolved.map { finding, summary in
                ReviewItem(itemID: finding.id, actionToken: .review, actionLabel: "View", summary: summary ?? finding.detail, subject: finding.subject, sender: finding.kind.rawValue, date: finding.date?.formatted(date: .abbreviated, time: .omitted), accountLabel: finding.location)
            }
            let payload = ReviewCardPayload(reviewType: .notes, items: items)
            let context = modelContainer.mainContext
            let chat: Chat
            if let targetChatID {
                var descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == targetChatID })
                descriptor.fetchLimit = 1
                guard let existing = try? context.fetch(descriptor).first else { return .invalid }
                chat = existing
                for old in chat.messages where old.reviewCard?.reviewType == .notes {
                    old.reviewCard = nil
                    old.content = "An updated Notes analysis has been requested."
                }
            } else {
                chat = Chat(title: "\(Chat.notesReviewTitlePrefix) \(Date.now.formatted(.dateTime.month(.abbreviated).day()))", modelSelection: SettingsStorage.loadModelSelection(forKey: SettingsKeys.clawModel))
                context.insert(chat)
            }
            let next = (chat.messages.map(\.sortIndex).max() ?? -1) + 1
            let card = ChatMessage(role: .assistant, content: "", sortIndex: next, reviewCard: payload)
            card.chat = chat; context.insert(card)
            let summary = ChatMessage(role: .assistant, content: message, sortIndex: next + 1)
            summary.chat = chat; context.insert(summary)
            chat.refreshLatestVisibleMessageAt()
            chat.updatedAt = .now
            do { try dependencies.save(context) }
            catch { context.rollback(); Self.logger.error("failed to save Notes review: \(String(describing: error))"); return .failed }
            hasPersistedForRun = true
            AppRouter.shared.noteNewChatMessages(in: chat.id)
            if targetChatID == nil {
                onReviewCreated?(chat.id, notification?.isEmpty == false ? notification! : message)
            }
            return .created(items.count)
        }
        switch outcome {
        case .skipped: return "Already created a Notes review for this pass — additional notify call ignored."
        case .invalid: throw ToolError.invalidArguments("target review chat was not found")
        case .failed: throw ToolError.executionFailed("the Notes review could not be saved and was NOT created")
        case let .created(count): return "\(targetChatID == nil ? "Created" : "Updated") Notes review with \(count) item\(count == 1 ? "" : "s")."
        }
    }
}
