import Foundation
import SwiftData

/// Routes the proposals a review run raised (via `ProposeMemoryTool`) into
/// a chat's review cards. Called by each review service after its inference
/// pass finishes:
///
/// - When the run produced (or targeted) a review chat, the cards land
///   there, right under the run's own findings.
/// - When it didn't (nothing to notify about, but a memory-worthy pattern
///   was still spotted), the cards land in a reusable unarchived
///   "Memory suggestions" chat — created on first need — so a proposal is
///   never silently orphaned.
///
/// Binding `MemoryProposal.chatID` here (it is nil at proposal time — the
/// review chat may not exist yet when the tool runs) is what lets
/// `MemoryCardCoordinator`'s persisted-state rehydration recover these
/// cards too if this pass is interrupted before draining.
/// Captures the chat a review run's notify tool created, for use as the
/// router's preferred destination. A tiny reference box because the notify
/// callback fires (or doesn't — no findings, no chat) long after the tool
/// wiring is built.
@MainActor
final class MemoryReviewChatCapture {
    var chatID: UUID?

    nonisolated init() {}
}

@MainActor
enum MemoryReviewProposalRouter {
    private static let logger = AppLog.make("memory")

    static func route(
        proposalIDs: [UUID],
        for feature: WorkspaceFeature,
        preferredChatID: UUID?,
        modelContainer: ModelContainer,
        coordinator: MemoryCardCoordinator = .shared
    ) {
        let context = modelContainer.mainContext

        var proposals = proposalIDs.compactMap { id -> MemoryProposal? in
            var descriptor = FetchDescriptor<MemoryProposal>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }
        .filter { $0.status == .pending && $0.cardPostedAt == nil }

        // Self-heal: a proposal from an earlier run that crashed before
        // routing still has a nil chatID — `MemoryCardCoordinator`'s
        // rehydration can't see it (that queries by chat), so each later
        // run of the same feature sweeps its source's orphans along.
        let seen = Set(proposals.map(\.id))
        for orphan in fetchOrphanedProposals(for: feature, in: context) where !seen.contains(orphan.id) {
            proposals.append(orphan)
        }
        guard !proposals.isEmpty else { return }

        guard let chat = resolveChat(preferredChatID: preferredChatID, in: context) else {
            logger.error("memory proposal routing found no usable chat; proposals stay pending")
            return
        }

        for proposal in proposals {
            proposal.chatID = chat.id
            coordinator.enqueueProposal(proposalID: proposal.id, chatID: chat.id)
        }
        coordinator.drain(for: chat, using: context)
        chat.updatedAt = .now
        do {
            try context.save()
        } catch {
            logger.error("memory proposal routing save failed: \(String(describing: error))")
            return
        }
        AppRouter.shared.noteNewChatMessages(in: chat.id)
    }

    private static func fetchOrphanedProposals(
        for feature: WorkspaceFeature,
        in context: ModelContext
    ) -> [MemoryProposal] {
        guard let source = MemoryProposal.Source(reviewing: feature) else { return [] }
        let sourceRawValue = source.rawValue
        let pendingRawValue = MemoryProposal.Status.pending.rawValue
        let descriptor = FetchDescriptor<MemoryProposal>(
            predicate: #Predicate {
                $0.sourceRawValue == sourceRawValue
                    && $0.statusRawValue == pendingRawValue
                    && $0.chatID == nil
                    && $0.cardPostedAt == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func resolveChat(preferredChatID: UUID?, in context: ModelContext) -> Chat? {
        if let preferredChatID {
            var descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == preferredChatID })
            descriptor.fetchLimit = 1
            if let chat = try? context.fetch(descriptor).first {
                return chat
            }
        }
        // Reuse the newest unarchived suggestions chat rather than minting
        // one per run — proposals are rare (cap 2) and scattered chats would
        // bury them.
        let prefix = Chat.memorySuggestionsTitlePrefix
        var existing = FetchDescriptor<Chat>(
            predicate: #Predicate { $0.title.starts(with: prefix) && !$0.isArchived },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        existing.fetchLimit = 1
        if let chat = try? context.fetch(existing).first {
            return chat
        }
        let chat = Chat(
            title: "\(prefix) \(Date.now.formatted(.dateTime.month(.abbreviated).day()))",
            modelSelection: SettingsStorage.loadModelSelection(forKey: SettingsKeys.clawModel)
        )
        context.insert(chat)
        chat.appendMessage(
            role: .assistant,
            content: "While reviewing, I noticed something that might be worth remembering. Each suggestion below is saved only if you accept it."
        )
        return chat
    }
}
