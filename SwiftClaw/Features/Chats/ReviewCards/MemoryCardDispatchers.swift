import Foundation
import SwiftData

/// Executes `.undo` on a `.memoryWrite` chip item. Undo means *the write
/// never happened*: a hard delete through `MemoryRepository.undoEntryWrite`
/// (which also un-stamps a fact the write superseded), guarded so it only
/// applies while the entry is unmodified and unsuperseded — a stale Undo
/// after the user edited the entry is a no-op, and the chip's own state
/// reload shows why.
@MainActor
final class MemoryWriteDispatcher: ReviewActionDispatcher {
    let reviewType: ReviewType = .memoryWrite

    private let repositoryProvider: @MainActor () -> MemoryRepository?

    init(
        repositoryProvider: @escaping @MainActor () -> MemoryRepository? = {
            MemoryFeatureModel.shared.repository
        }
    ) {
        self.repositoryProvider = repositoryProvider
    }

    func perform(action: ReviewActionToken, itemID: UUID) async {
        guard action == .undo,
              let repository = repositoryProvider(),
              let entry = repository.entry(id: itemID) else { return }
        // `notUndoable` (edited/superseded since) is an expected outcome,
        // not an error — the renderer re-reads state and disables Undo.
        try? repository.undoEntryWrite(entry)
    }
}

/// Executes `.approve`/`.reject` on a `MemoryProposal` — the far simpler
/// cousin of `NoteProposalDispatcher`: no vault, no lease, no base-hash
/// race. Statuses are still two-phase (`.applying` persisted before any
/// repository write, terminal state persisted after) so a crash mid-apply
/// never leaves a proposal that looks re-approvable, and both actions are
/// idempotent from any non-pending status.
///
/// Approval never force-files: a vanished target collection routes the
/// entry to the Inbox; a `newCollectionTitle` creates that collection (its
/// seed entries ride in `entryText`, newline-separated); a vanished or
/// already-superseded supersession target degrades to a plain add — the
/// approved fact always lands somewhere visible.
@MainActor
final class MemoryProposalDispatcher: ReviewActionDispatcher {
    let reviewType: ReviewType = .memoryProposal

    private static let logger = AppLog.make("memory")

    private let modelContainer: ModelContainer
    private let repositoryProvider: @MainActor () -> MemoryRepository?

    init(
        modelContainer: ModelContainer,
        repositoryProvider: @escaping @MainActor () -> MemoryRepository? = {
            MemoryFeatureModel.shared.repository
        }
    ) {
        self.modelContainer = modelContainer
        self.repositoryProvider = repositoryProvider
    }

    func perform(action: ReviewActionToken, itemID: UUID) async {
        let context = ModelContext(modelContainer)
        guard let proposal = Self.fetchProposal(id: itemID, in: context) else { return }
        guard proposal.status == .pending else { return }

        switch action {
        case .approve:
            approve(proposal, in: context)
        case .reject:
            reject(proposal, in: context)
        case .review, .flag, .reply, .delete, .archive, .edit, .undo:
            // `.edit` is handled inside the card (the sheet saves modified
            // text, then dispatches `.approve`); nothing else applies here.
            break
        }
    }

    private func approve(_ proposal: MemoryProposal, in context: ModelContext) {
        guard let repository = repositoryProvider() else { return }

        proposal.status = .applying
        guard (try? context.save()) != nil else { return }

        // The target collection, every entry, and the acceptance event land
        // in one repository save — all or nothing — so a failed save can
        // never leave a half-applied proposal or a proposal marked applied
        // whose entries were rolled back.
        do {
            try repository.performBatch {
                let target = try resolveTargetCollection(for: proposal, repository: repository)
                for text in Self.entryTexts(for: proposal) {
                    try writeEntry(
                        text: text,
                        proposal: proposal,
                        target: target,
                        repository: repository
                    )
                }
                try repository.recordProposalResolution(accepted: true, proposal: proposal, collectionID: target.id)
            }
        } catch {
            // Nothing persisted: return the proposal to `.pending` so the
            // card offers Accept again instead of claiming it saved.
            Self.logger.error("Memory proposal approval failed: \(String(describing: error))")
            proposal.status = .pending
            try? context.save()
            return
        }

        proposal.status = .applied
        proposal.resolvedAt = .now
        // If this save fails the writes still happened: leave `.applying`
        // (never re-approvable) rather than pretending nothing happened.
        // The entries are saved and disclosed by this card.
        try? context.save()
    }

    private func reject(_ proposal: MemoryProposal, in context: ModelContext) {
        proposal.status = .rejected
        proposal.resolvedAt = .now
        guard (try? context.save()) != nil else { return }
        // Rejected proposals persist — their texts feed review runs'
        // "previously declined" suppression context (Phase 3).
        try? repositoryProvider()?.recordProposalResolution(
            accepted: false,
            proposal: proposal,
            collectionID: proposal.targetCollectionID
        )
    }

    private func resolveTargetCollection(
        for proposal: MemoryProposal,
        repository: MemoryRepository
    ) throws -> MemoryCollection {
        if let targetID = proposal.targetCollectionID,
           let existing = repository.collection(id: targetID) {
            return existing
        }
        if let title = proposal.newCollectionTitle {
            // Approval may race a duplicate creation; reuse an
            // identically-titled collection rather than minting a twin.
            if let existing = repository.collections().first(where: {
                $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                return existing
            }
            return try repository.createCollection(
                title: title,
                details: proposal.newCollectionDetails,
                tags: proposal.tags,
                accessLevel: proposal.newCollectionAccessLevel ?? .writesFreely,
                scope: proposal.scope,
                createdBy: .ai,
                chatID: proposal.chatID
            )
        }
        // Target vanished between proposing and approving — never
        // force-file; the Inbox is the pressure valve.
        return try repository.ensureInbox()
    }

    /// Writes carry `disclosedAt` in the same repository save as the entry
    /// itself: the proposal card the user just accepted *is* the disclosure,
    /// and a crash between an undisclosed write and a later marker save
    /// would make `MemoryCardCoordinator`'s rehydration post a duplicate
    /// chip on the chat's next turn.
    private func writeEntry(
        text: String,
        proposal: MemoryProposal,
        target: MemoryCollection,
        repository: MemoryRepository
    ) throws {
        // Only ever called inside `performBatch`, where saves are deferred:
        // `supersedeEntry` can then throw only its pre-mutation
        // `alreadySuperseded` guard, so falling back to a plain add is safe.
        if let supersedesID = proposal.supersedesEntryID,
           let old = repository.entry(id: supersedesID),
           old.supersededByID == nil,
           (try? repository.supersedeEntry(
               old,
               withBody: text,
               tags: proposal.tags.isEmpty ? nil : proposal.tags,
               createdBy: .ai,
               sourceChatID: proposal.chatID,
               disclosedAt: .now
           )) != nil {
            return
        }
        try repository.addEntry(
            body: text,
            tags: proposal.tags,
            to: target,
            createdBy: .ai,
            sourceChatID: proposal.chatID,
            disclosedAt: .now
        )
    }

    /// New-collection proposals carry their seed entries newline-separated
    /// in `entryText` (see `CreateMemoryCollectionTool`); everything else is
    /// one entry. A seedless new-collection proposal writes no entries.
    static func entryTexts(for proposal: MemoryProposal) -> [String] {
        guard proposal.newCollectionTitle != nil else {
            let text = proposal.entryText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [text]
        }
        return proposal.entryText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func fetchProposal(id: UUID, in context: ModelContext) -> MemoryProposal? {
        var descriptor = FetchDescriptor<MemoryProposal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
