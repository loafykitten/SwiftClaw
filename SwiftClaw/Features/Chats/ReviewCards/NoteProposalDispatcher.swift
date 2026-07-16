import Foundation
import SwiftData

/// Executes `.approve`/`.reject` on a `NoteEditProposal` (resolved via
/// `ReviewActionToken`). Never routed through `EmailReviewActionDispatcher` —
/// registered separately as its own `.noteProposal` dispatcher.
///
/// `.approve` requires a nonnil `proposal.originatingVaultID` (captured when
/// the proposal tool ran) — a proposal that predates that capture, or whose
/// vault can no longer be confirmed live, is unbound and is marked `.expired`
/// with **no repository read or mutation**; safety wins over the legacy
/// convenience of treating a missing id as "assume it matches." Before doing
/// anything else, `.approve` also acquires a `VaultOperationLease` for that
/// vault id (`acquireVaultOperationLease`) and holds it for the *entire*
/// approval file operation, releasing it in a `defer` — this is what stops a
/// concurrent vault switch/reset from tearing down the live vault out from
/// under an approval that's already suspended mid-read/write (see
/// `NotesFeatureModel.acquireVaultOperationLease`/`teardownCurrentVault`). A
/// mismatched or unavailable vault (lease denied) also marks the proposal
/// `.expired` and returns without touching `repositoryProvider` or the vault
/// at all. Only with a held lease does `.approve` re-read the target note; its
/// `baseContentHash` is then passed to `NotesVault`'s coordinated conditional
/// replacement, where the authoritative comparison and atomic publish happen
/// in one document-coordination access. An edit made to the note between
/// proposal and approval is never silently clobbered; the proposal is marked
/// `.conflicted` instead and the original file is left untouched. A clean
/// approve applies through `NotesRepository` only, so the existing
/// hash-guarded write + pre-mutation revision snapshot behavior runs
/// unchanged.
///
/// Status transitions are durable and two-phase: before any file mutation,
/// the proposal is marked `.applying` and persisted — if that preflight save
/// fails, nothing is mutated. After a successful file mutation, the proposal
/// is marked `.applied`/`resolvedAt` and persisted again; if *that* save
/// fails, the file mutation has already happened but the durable status stays
/// `.applying` (never `.pending`, so `perform`'s idempotency guard below
/// makes it permanently non-reappliable) and the posted outcome says so
/// plainly instead of claiming a misleading "Applied". Every other terminal
/// transition (`.conflicted`/`.expired`/`.rejected`) also only posts its
/// outcome message once its own persistence actually succeeds. An
/// infrastructure failure during the file operation restores `.pending`,
/// so the proposal remains retryable without claiming that the note
/// changed. Status saves roll their context back on failure, and outcome
/// messages always use a
/// separate fresh context, so saving a message can never accidentally carry a
/// dirty proposal status along with it.
///
/// Both actions are idempotent: a second action on an already-resolved (or
/// `.applying`) proposal is a no-op. `.reject` never touches the vault, so it
/// skips the vault-identity/lease check entirely.
@MainActor
final class NoteProposalDispatcher: ReviewActionDispatcher {
    let reviewType: ReviewType = .noteProposal

    private let modelContainer: ModelContainer
    /// Seam so tests can point approval at a `NotesRepository` backed by a
    /// temporary vault instead of the live `NotesFeatureModel.shared`.
    private let repositoryProvider: @MainActor () -> NotesRepository?
    /// Seam so tests can simulate vault identity/lease behavior (including a
    /// concurrent teardown/switch) with an injected
    /// `VaultOperationLeaseCoordinator` instead of the live
    /// `NotesFeatureModel.shared`/real settings.
    private let acquireVaultOperationLease: @MainActor (String) -> VaultOperationLeaseCoordinator.Lease?
    /// Narrow status-save seam: production uses `ModelContext.save()`, while
    /// focused tests can fail a specific ordered status transition.
    private let saveProposalStatus: @MainActor (ModelContext) throws -> Void

    init(
        modelContainer: ModelContainer,
        repositoryProvider: @escaping @MainActor () -> NotesRepository? = { NotesFeatureModel.shared.repository },
        acquireVaultOperationLease: @escaping @MainActor (String) -> VaultOperationLeaseCoordinator.Lease? = {
            NotesFeatureModel.shared.acquireVaultOperationLease(expectedVaultID: $0)
        },
        saveProposalStatus: @escaping @MainActor (ModelContext) throws -> Void = { context in
            try context.save()
        }
    ) {
        self.modelContainer = modelContainer
        self.repositoryProvider = repositoryProvider
        self.acquireVaultOperationLease = acquireVaultOperationLease
        self.saveProposalStatus = saveProposalStatus
    }

    func perform(action: ReviewActionToken, itemID: UUID) async {
        let context = ModelContext(modelContainer)
        guard let proposal = Self.fetchProposal(id: itemID, in: context) else { return }
        // Idempotent: a second approve/reject on an already-resolved (or
        // `.applying` — an interrupted approve whose final persistence
        // failed, see `approve` below) proposal is a no-op rather than
        // re-applying or re-posting.
        guard proposal.status == .pending else { return }

        switch action {
        case .approve:
            await approve(proposal, in: context)
        case .reject:
            reject(proposal, in: context)
        case .review, .flag, .reply, .delete, .archive:
            break
        }
    }

    // MARK: - Reject

    private func reject(_ proposal: NoteEditProposal, in context: ModelContext) {
        proposal.status = .rejected
        proposal.resolvedAt = .now
        guard persist(context) else { return }
        postOutcome("Rejected the proposed \(kindLabel(proposal.kind)) to \(proposal.notePath).", chatID: proposal.chatID)
    }

    // MARK: - Approve

    private struct ProposalConflict: Error {}

    private func approve(_ proposal: NoteEditProposal, in context: ModelContext) async {
        let chatID = proposal.chatID
        // A missing `originatingVaultID` is unbound — never treated as
        // "assume it matches". Safety wins over the legacy convenience of
        // applying a proposal that predates this check.
        guard let originatingVaultID = proposal.originatingVaultID else {
            markExpired(proposal, in: context)
            return
        }

        // Acquired *before* any repository read/mutation and held for the
        // entire operation (released in `defer`) — this is what stops a
        // concurrent vault teardown/switch from invalidating the vault this
        // approval is about to use while it's suspended mid-operation. A
        // denied lease covers both "wrong vault" and "no vault currently
        // configured" — either way, nothing is read or written.
        guard let lease = acquireVaultOperationLease(originatingVaultID) else {
            markExpired(proposal, in: context)
            return
        }
        defer { lease.release() }

        guard let repository = repositoryProvider() else {
            markConflicted(proposal, in: context)
            return
        }

        // Durable two-phase state: persisted `.applying` *before* any file
        // mutation. If this preflight save fails, nothing is mutated and the
        // proposal is left `.pending` in the store (safe to retry).
        proposal.status = .applying
        guard persist(context) else { return }

        do {
            switch proposal.kind {
            case .create:
                try await applyCreate(proposal, repository: repository)
            case .edit:
                try await applyEdit(proposal, repository: repository)
            case .append:
                try await applyAppend(proposal, repository: repository)
            case .rename:
                try await applyRename(proposal, repository: repository)
            }
        } catch is ProposalConflict {
            markConflicted(proposal, in: context)
            return
        } catch let error as NotesError {
            switch error {
            case .externalConflict(_), .pathAlreadyExists(_):
                markConflicted(proposal, in: context)
            case .partialLoadFailure(_), .createFailed(_), .invalidNotePath(_),
                 .revisionNotFound(_), .underlying(_):
                restorePendingAfterOperationFailure(proposal, in: context)
            }
            return
        } catch {
            restorePendingAfterOperationFailure(proposal, in: context)
            return
        }

        proposal.status = .applied
        proposal.resolvedAt = .now
        guard persist(context) else {
            // The file mutation already succeeded, but the durable status
            // couldn't be recorded. The proposal stays `.applying` — never
            // `.pending` again, so `perform`'s idempotency guard makes this
            // permanently non-reappliable rather than risking a duplicate
            // mutation on a retry — and the outcome says so plainly instead
            // of claiming a misleading "Applied".
            postOutcome(
                "The proposed change may have reached \(proposal.notePath), but SwiftClaw couldn't save its applied status. "
                    + "Please verify the note directly, or ask me to re-propose.",
                chatID: chatID
            )
            return
        }
        postOutcome("Applied the proposed \(kindLabel(proposal.kind)) to \(proposal.notePath).", chatID: chatID)
    }

    /// `.create`: never overwrites an existing path and never writes a
    /// "(conflict …)" sibling on collision — a read-then-`save` sequence
    /// would race an external editor creating the same path between the two
    /// separate vault operations, so this goes through `NotesRepository
    /// .createExactPath`, which is backed by a single atomic exclusive-create
    /// vault operation instead.
    private func applyCreate(_ proposal: NoteEditProposal, repository: NotesRepository) async throws {
        _ = try await repository.createExactPath(
            relativePath: proposal.notePath,
            content: proposal.proposedContent ?? ""
        )
    }

    private func applyEdit(_ proposal: NoteEditProposal, repository: NotesRepository) async throws {
        let current = try await repository.read(relativePath: proposal.notePath)
        guard current.sha256 == proposal.baseContentHash else {
            throw ProposalConflict()
        }
        _ = try await repository.save(
            relativePath: proposal.notePath,
            content: proposal.proposedContent ?? current.content,
            expectedHash: proposal.baseContentHash
        )
    }

    /// Applies the stored full resulting content when present (the tool
    /// captured it up front); otherwise derives it by appending
    /// `appendText` to the just-re-read current content.
    private func applyAppend(_ proposal: NoteEditProposal, repository: NotesRepository) async throws {
        let current = try await repository.read(relativePath: proposal.notePath)
        guard current.sha256 == proposal.baseContentHash else {
            throw ProposalConflict()
        }
        let resultingContent: String
        if let proposedContent = proposal.proposedContent {
            resultingContent = proposedContent
        } else {
            let appendText = proposal.appendText ?? ""
            resultingContent = current.content.isEmpty ? appendText : current.content + "\n" + appendText
        }
        _ = try await repository.save(
            relativePath: proposal.notePath,
            content: resultingContent,
            expectedHash: proposal.baseContentHash
        )
    }

    private func applyRename(_ proposal: NoteEditProposal, repository: NotesRepository) async throws {
        guard let newPath = proposal.newPath else { throw ProposalConflict() }
        let current = try await repository.read(relativePath: proposal.notePath)
        guard current.sha256 == proposal.baseContentHash else {
            throw ProposalConflict()
        }
        _ = try await repository.rename(from: proposal.notePath, to: newPath)
    }

    private func markConflicted(_ proposal: NoteEditProposal, in context: ModelContext) {
        proposal.status = .conflicted
        proposal.resolvedAt = .now
        guard persist(context) else { return }
        postOutcome("Note changed since proposed — not applied; ask me to re-propose.", chatID: proposal.chatID)
    }

    private func markExpired(_ proposal: NoteEditProposal, in context: ModelContext) {
        proposal.status = .expired
        proposal.resolvedAt = .now
        guard persist(context) else { return }
        postOutcome("The notes vault changed since this was proposed — not applied; ask me to re-propose.", chatID: proposal.chatID)
    }

    private func restorePendingAfterOperationFailure(_ proposal: NoteEditProposal, in context: ModelContext) {
        // `.applying` was already persisted before the vault operation. Return
        // to a durably retryable state only after the failed operation has
        // completed; if this save fails, `persist` rolls back to that safe,
        // non-reapplicable `.applying` record instead of leaving a dirty
        // `.pending` state that a later unrelated save could publish.
        proposal.status = .pending
        proposal.resolvedAt = nil
        guard persist(context) else { return }
        postOutcome(
            "Couldn't complete the proposed \(kindLabel(proposal.kind)) to \(proposal.notePath). "
                + "SwiftClaw couldn't confirm whether the note changed, so the proposal is still available to retry. "
                + "Please verify the note before trying again.",
            chatID: proposal.chatID
        )
    }

    // MARK: - Persistence

    /// Every terminal (or intermediate `.applying`) status transition must be
    /// durably saved before its outcome message is posted — posting a
    /// message the persisted state doesn't actually reflect would mislead
    /// the user into believing a status a restart could silently revert.
    @discardableResult
    private func persist(_ context: ModelContext) -> Bool {
        do {
            try saveProposalStatus(context)
            return true
        } catch {
            // Do not leave a dirty terminal status registered in this context:
            // a later save (historically `postOutcome`) could otherwise
            // persist it despite reporting a failure. For the final applied
            // save this restores the already-durable `.applying` state; for a
            // preflight failure it restores `.pending` before any file access.
            context.rollback()
            return false
        }
    }

    // MARK: - Outcome

    private func postOutcome(_ message: String, chatID: UUID?) {
        guard let chatID else { return }
        // Never reuse the proposal-status context here. A fresh context fetches
        // and saves only the chat/message graph, so an unsaved proposal status
        // cannot hitch a ride on outcome-message persistence.
        let outcomeContext = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == chatID })
        descriptor.fetchLimit = 1
        guard let chat = try? outcomeContext.fetch(descriptor).first else { return }
        chat.appendMessage(role: .assistant, content: message)
        try? outcomeContext.save()
    }

    private func kindLabel(_ kind: NoteEditProposal.Kind) -> String {
        switch kind {
        case .create: "create"
        case .edit: "edit"
        case .append: "append"
        case .rename: "rename"
        }
    }

    private static func fetchProposal(id: UUID, in context: ModelContext) -> NoteEditProposal? {
        var descriptor = FetchDescriptor<NoteEditProposal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
