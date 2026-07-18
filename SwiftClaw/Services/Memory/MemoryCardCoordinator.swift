import Foundation
import Observation
import SwiftData

/// Pending-disclosure queue between the memory write tools and
/// `ChatCompletionService` — the `NotesProposalCoordinator` pattern, carrying
/// two kinds of disclosure:
///
/// - **Writes** (`.memoryWrite` chip): autonomous writes to writes-freely
///   collections. One chip card per turn, one item per written entry, each
///   with View + Undo. Durability marker: `MemoryEntry.disclosedAt` — a
///   write whose completion failed before draining still gets exactly one
///   chip on that chat's next successful turn (rehydrated by querying
///   undisclosed AI entries for the chat).
/// - **Proposals** (`.memoryProposal` card): asks-first writes and (Phase 3)
///   background `propose_memory` runs. One card per proposal, Accept / Edit /
///   Dismiss. Durability marker: `MemoryProposal.cardPostedAt`.
///
/// Like the Notes coordinator: queues are scoped per chat id, `drain` never
/// saves (the caller's save covers the assistant reply and every card in one
/// transaction), and posting marks the durable marker in the same pass so a
/// second drain can never double-post.
@MainActor
@Observable
final class MemoryCardCoordinator: @unchecked Sendable {
    static let shared = MemoryCardCoordinator()

    private var queuedWriteEntryIDsByChatID: [UUID: [UUID]] = [:]
    private var queuedCollectionCreationsByChatID: [UUID: [UUID]] = [:]
    private var queuedProposalIDsByChatID: [UUID: [UUID]] = [:]

    init() {}

    func enqueueWrite(entryID: UUID, chatID: UUID) {
        queuedWriteEntryIDsByChatID[chatID, default: []].append(entryID)
    }

    /// A writes-freely collection the AI just created (with or without seed
    /// entries). In-memory only — a lost "created collection" chip is the
    /// one disclosure without a durable marker; the collection itself stays
    /// visible in the Memory UI and activity feed either way.
    func enqueueCollectionCreation(collectionID: UUID, chatID: UUID) {
        queuedCollectionCreationsByChatID[chatID, default: []].append(collectionID)
    }

    func enqueueProposal(proposalID: UUID, chatID: UUID) {
        queuedProposalIDsByChatID[chatID, default: []].append(proposalID)
    }

    /// Test seam.
    func hasQueuedDisclosures(forChatID chatID: UUID) -> Bool {
        !(queuedWriteEntryIDsByChatID[chatID]?.isEmpty ?? true)
            || !(queuedCollectionCreationsByChatID[chatID]?.isEmpty ?? true)
            || !(queuedProposalIDsByChatID[chatID]?.isEmpty ?? true)
    }

    func drain(for chat: Chat, using modelContext: ModelContext) {
        drainWrites(for: chat, using: modelContext)
        drainProposals(for: chat, using: modelContext)
    }

    // MARK: - Write chips

    private func drainWrites(for chat: Chat, using modelContext: ModelContext) {
        let queuedEntryIDs = queuedWriteEntryIDsByChatID.removeValue(forKey: chat.id) ?? []
        let queuedCollectionIDs = queuedCollectionCreationsByChatID.removeValue(forKey: chat.id) ?? []

        var entriesToDisclose: [MemoryEntry] = []
        var seenEntryIDs: Set<UUID> = []
        for entryID in queuedEntryIDs {
            guard let entry = Self.fetchEntry(id: entryID, in: modelContext),
                  entry.disclosedAt == nil,
                  seenEntryIDs.insert(entry.id).inserted else { continue }
            entriesToDisclose.append(entry)
        }
        // Rehydration: any undisclosed AI write bound to this chat that the
        // in-memory queue lost (failed/cancelled turn, process restart).
        for entry in Self.fetchUndisclosedAIEntries(chatID: chat.id, in: modelContext)
        where seenEntryIDs.insert(entry.id).inserted {
            entriesToDisclose.append(entry)
        }

        var items: [ReviewItem] = []
        for collectionID in queuedCollectionIDs {
            guard let collection = Self.fetchCollection(id: collectionID, in: modelContext) else { continue }
            items.append(ReviewItem(
                itemID: collection.id,
                actionToken: .review,
                actionLabel: "View",
                summary: "New collection",
                subject: collection.title
            ))
        }
        for entry in entriesToDisclose {
            items.append(ReviewItem(
                itemID: entry.id,
                actionToken: .undo,
                actionLabel: "Undo",
                summary: entry.body,
                subject: entry.collection?.title
            ))
            entry.disclosedAt = .now
        }
        guard !items.isEmpty else { return }
        chat.appendMessage(
            role: .assistant,
            content: "",
            reviewCard: ReviewCardPayload(reviewType: .memoryWrite, items: items)
        )
    }

    // MARK: - Proposal cards

    private func drainProposals(for chat: Chat, using modelContext: ModelContext) {
        let queuedProposalIDs = queuedProposalIDsByChatID.removeValue(forKey: chat.id) ?? []

        var proposalsToPost: [MemoryProposal] = []
        var seenProposalIDs: Set<UUID> = []
        for proposalID in queuedProposalIDs {
            guard let proposal = Self.fetchProposal(id: proposalID, in: modelContext),
                  proposal.status == .pending, proposal.cardPostedAt == nil,
                  seenProposalIDs.insert(proposal.id).inserted else { continue }
            proposalsToPost.append(proposal)
        }
        for proposal in Self.fetchPendingUnpostedProposals(chatID: chat.id, in: modelContext)
        where seenProposalIDs.insert(proposal.id).inserted {
            proposalsToPost.append(proposal)
        }
        guard !proposalsToPost.isEmpty else { return }

        for proposal in proposalsToPost {
            let payload = ReviewCardPayload(
                reviewType: .memoryProposal,
                items: [
                    ReviewItem(
                        itemID: proposal.id,
                        actionToken: .approve,
                        actionLabel: "Review",
                        summary: proposal.summary,
                        subject: proposal.newCollectionTitle
                            ?? proposal.targetCollectionID
                                .flatMap { Self.fetchCollection(id: $0, in: modelContext) }?.title
                    ),
                ]
            )
            chat.appendMessage(role: .assistant, content: "", reviewCard: payload)
            proposal.cardPostedAt = .now
        }
    }

    // MARK: - Fetches

    private static func fetchEntry(id: UUID, in modelContext: ModelContext) -> MemoryEntry? {
        var descriptor = FetchDescriptor<MemoryEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private static func fetchCollection(id: UUID, in modelContext: ModelContext) -> MemoryCollection? {
        var descriptor = FetchDescriptor<MemoryCollection>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private static func fetchProposal(id: UUID, in modelContext: ModelContext) -> MemoryProposal? {
        var descriptor = FetchDescriptor<MemoryProposal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private static func fetchUndisclosedAIEntries(chatID: UUID, in modelContext: ModelContext) -> [MemoryEntry] {
        let boundChatID: UUID? = chatID
        let aiRawValue = MemoryActor.ai.rawValue
        let descriptor = FetchDescriptor<MemoryEntry>(
            predicate: #Predicate {
                $0.sourceChatID == boundChatID
                    && $0.createdByRawValue == aiRawValue
                    && $0.disclosedAt == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func fetchPendingUnpostedProposals(chatID: UUID, in modelContext: ModelContext) -> [MemoryProposal] {
        let boundChatID: UUID? = chatID
        let pendingRawValue = MemoryProposal.Status.pending.rawValue
        let descriptor = FetchDescriptor<MemoryProposal>(
            predicate: #Predicate {
                $0.chatID == boundChatID && $0.statusRawValue == pendingRawValue && $0.cardPostedAt == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
