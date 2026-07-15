import Foundation
import Observation
import SwiftData

/// Pending-proposal queue between note-proposing tools
/// (`ProposeNoteEditTool`/`ProposeNoteCreateTool`) and `ChatCompletionService`.
///
/// A tool call happens deep inside `InferenceService`'s agentic tool loop,
/// with no chance to append a `ChatMessage` of its own mid-loop, so it just
/// persists its `NoteEditProposal` and enqueues the id here.
/// `ChatCompletionService` drains the queue for its own chat right after
/// appending the assistant's own text message and before saving, so the
/// assistant's reply and every proposal card it produced land in the same
/// save, in the same chat — see `ChatCompletionService.completeScopedChat`.
///
/// Queues are scoped per chat id: a completion running on chat A can never
/// drain proposals queued by a completion on chat B, because `drain` only
/// ever looks up `chat.id`. A completion that fails or is cancelled before
/// draining simply leaves its proposals queued under that chat's id — they
/// are not lost (already persisted in the store) and are posted the next
/// time that same chat completes successfully.
///
/// The in-memory queue alone isn't durable across a process restart, so
/// `drain` also queries SwiftData directly for any `.pending` proposal
/// belonging to `chat.id` whose card was never posted
/// (`NoteEditProposal.cardPostedAt == nil`) — this is what lets a proposal
/// saved by a tool before a failed/cancelled completion (or before a relaunch
/// wiped the in-memory queue) still get exactly one card on the next
/// successful completion for its own chat. `cardPostedAt` is the sole
/// dedup/attachment marker: it's set (in the same pass, before the caller's
/// `modelContext.save()`) the moment a card is appended, so neither a second
/// `drain` call nor an overlapping in-memory-queue + persisted-query result
/// for the same id ever produces two cards.
@MainActor
@Observable
final class NotesProposalCoordinator: @unchecked Sendable {
    static let shared = NotesProposalCoordinator()

    private var queuedProposalIDsByChatID: [UUID: [UUID]] = [:]

    init() {}

    func enqueue(proposalID: UUID, chatID: UUID) {
        queuedProposalIDsByChatID[chatID, default: []].append(proposalID)
    }

    /// Whether `chatID` currently has anything queued — test seam.
    func hasQueuedProposals(forChatID chatID: UUID) -> Bool {
        !(queuedProposalIDsByChatID[chatID]?.isEmpty ?? true)
    }

    /// Appends one `.noteProposal` review-card `ChatMessage` per not-yet-posted
    /// `.pending` proposal belonging to `chat.id` — combining the in-memory
    /// queue (enqueue order) with a direct SwiftData rehydration query for
    /// anything the queue lost — then marks each posted via `cardPostedAt`.
    /// Never calls `modelContext.save()` itself — the caller saves once,
    /// covering the assistant's own message and every card appended here.
    func drain(for chat: Chat, using modelContext: ModelContext) {
        let queuedProposalIDs = queuedProposalIDsByChatID.removeValue(forKey: chat.id) ?? []

        var proposalsToPost: [NoteEditProposal] = []
        var seenProposalIDs: Set<UUID> = []

        // Queued ids first, preserving enqueue order — these are almost
        // always this turn's freshly proposed cards.
        for proposalID in queuedProposalIDs {
            guard let proposal = Self.fetchProposal(id: proposalID, in: modelContext),
                  proposal.status == .pending, proposal.cardPostedAt == nil,
                  seenProposalIDs.insert(proposal.id).inserted else { continue }
            proposalsToPost.append(proposal)
        }

        // Then anything persisted-but-unposted for this chat that the queue
        // doesn't already know about — a prior completion's proposal that
        // never got drained (failed/cancelled turn, or a lost in-memory
        // queue after a relaunch).
        for proposal in Self.fetchPendingUnpostedProposals(chatID: chat.id, in: modelContext)
        where seenProposalIDs.insert(proposal.id).inserted {
            proposalsToPost.append(proposal)
        }

        guard !proposalsToPost.isEmpty else { return }

        for proposal in proposalsToPost {
            let payload = ReviewCardPayload(
                reviewType: .noteProposal,
                items: [
                    ReviewItem(
                        itemID: proposal.id,
                        actionToken: .approve,
                        actionLabel: "Review",
                        summary: proposal.summary,
                        subject: proposal.notePath
                    ),
                ]
            )
            chat.appendMessage(role: .assistant, content: "", reviewCard: payload)
            proposal.cardPostedAt = .now
        }
    }

    private static func fetchProposal(id: UUID, in modelContext: ModelContext) -> NoteEditProposal? {
        var descriptor = FetchDescriptor<NoteEditProposal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private static func fetchPendingUnpostedProposals(chatID: UUID, in modelContext: ModelContext) -> [NoteEditProposal] {
        // `NoteEditProposal.chatID` is `UUID?` — bind an explicitly optional
        // copy so the `#Predicate` comparison's operand types match exactly
        // rather than relying on implicit optional promotion inside the macro.
        let boundChatID: UUID? = chatID
        let pendingRawValue = NoteEditProposal.Status.pending.rawValue
        let descriptor = FetchDescriptor<NoteEditProposal>(
            predicate: #Predicate {
                $0.chatID == boundChatID && $0.statusRawValue == pendingRawValue && $0.cardPostedAt == nil
            },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
