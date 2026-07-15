import Foundation
import SwiftData

/// Proposes a full-content replacement for an existing note. **Never writes
/// the vault** — it captures the note's current `sha256` (the approve-time
/// conflict guard, see `NoteProposalDispatcher`), inserts a `pending`
/// `NoteEditProposal` into the chat's `ModelContainer`, and queues its id on
/// `NotesProposalCoordinator` so `ChatCompletionService` posts a review card
/// once the assistant's own reply is appended.
///
/// Constructed fresh per completion (needs the current chat's id and
/// `ModelContainer`) rather than living on `ToolRegistry.shared` — see
/// `ChatCompletionService`.
struct ProposeNoteEditTool: Tool {
    /// Seam so gating/reads can be exercised with stubs in tests instead of
    /// the live `NotesFeatureModel` singleton — mirrors `ReadNoteTool.Dependencies`.
    struct Dependencies: Sendable {
        var isAvailable: @MainActor @Sendable () -> Bool
        /// Returns `nil` when the note doesn't exist (or isn't readable) —
        /// `execute` turns that into a clear "use propose_note_create" error
        /// rather than a generic failure.
        var readCurrentSnapshot: @MainActor @Sendable (_ relativePath: String) async throws -> NoteFileSnapshot?
        /// Captures the vault identity a proposal is bound to — see
        /// `NoteEditProposal.originatingVaultID`. Defaulted (rather than
        /// required) so pre-existing test call sites that construct
        /// `Dependencies` without it keep compiling.
        var currentVaultID: @MainActor @Sendable () -> String? = { NotesFeatureModel.shared.configurationStore.vaultID }

        static let live = Dependencies(
            isAvailable: { NotesFeatureModel.shared.isAvailableForReadTools },
            readCurrentSnapshot: { path in
                do {
                    return try await NotesFeatureModel.shared.readNoteForTool(relativePath: path)
                } catch let toolError as ToolError {
                    // `.notConfigured` (a vault reset/switch invalidated an
                    // in-flight read) must reach the caller as-is; any other
                    // failure (e.g. the note doesn't exist) becomes `nil` so
                    // `execute` can report a clear "doesn't exist" error.
                    if case .notConfigured = toolError { throw toolError }
                    return nil
                }
            }
        )
    }

    let name = "propose_note_edit"
    let displayName = "Propose Note Edit"
    let description = """
        Propose replacing an existing note's full content. This is gated \
        behind explicit user approval — it never modifies the vault directly. \
        Provide the note's complete new content, not a patch or diff. Use \
        propose_note_create instead for a note that doesn't exist yet.
        """
    let systemImage = "pencil.and.outline"

    let parameters = [
        ToolParameter(
            name: "path",
            type: .string,
            description: "Vault-relative path of the note to edit, e.g. \"folder/Note.md\".",
            isRequired: true
        ),
        ToolParameter(
            name: "content",
            type: .string,
            description: "The note's complete new content (the full file, not a diff).",
            isRequired: true
        ),
        ToolParameter(
            name: "summary",
            type: .string,
            description: "A short, one-sentence human-readable summary of the change, shown on the review card.",
            isRequired: true
        ),
    ]

    private let modelContainer: ModelContainer
    private let chatID: UUID
    private let coordinator: NotesProposalCoordinator
    private let dependencies: Dependencies

    /// `@MainActor` rather than relying on `MainActor.assumeIsolated` inside
    /// a nonisolated init body — every real call site (`ChatCompletionService`,
    /// tests marked `@MainActor`) already constructs this on the main actor,
    /// so making that the compiler-enforced contract removes a runtime
    /// isolation trap for no loss of flexibility.
    @MainActor
    init(
        modelContainer: ModelContainer,
        chatID: UUID,
        coordinator: NotesProposalCoordinator? = nil,
        dependencies: Dependencies = .live
    ) {
        self.modelContainer = modelContainer
        self.chatID = chatID
        self.coordinator = coordinator ?? NotesProposalCoordinator.shared
        self.dependencies = dependencies
    }

    /// `MainActor.assumeIsolated` is safe here: both call sites that read
    /// `Tool.isConfigured` (`ChatCompletionService`, `ToolsView`) are
    /// themselves `@MainActor`.
    var isConfigured: Bool {
        MainActor.assumeIsolated {
            dependencies.isAvailable()
        }
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard await dependencies.isAvailable() else {
            throw ToolError.notConfigured(
                toolName: displayName,
                reason: "Notes is disabled, or no vault/index is configured."
            )
        }

        guard let path = arguments["path"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw ToolError.missingArgument("path")
        }
        guard VaultIgnoreRules.isVisibleMarkdownNotePath(path) else {
            throw ToolError.invalidArguments("path must be a visible vault-relative Markdown note")
        }
        guard let content = arguments["content"]?.stringValue else {
            throw ToolError.missingArgument("content")
        }
        guard let summary = arguments["summary"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else {
            throw ToolError.missingArgument("summary")
        }

        // Captured *before* the read/suspension, and re-captured immediately
        // after — a vault switch that lands entirely inside that window must
        // never let this proposal bind vault A's content/hash to vault B's
        // id (or vice versa). Both captures must be nonnil and equal, or the
        // proposal is refused outright rather than persisted with a stale or
        // ambiguous vault identity.
        guard let vaultIDBefore = await dependencies.currentVaultID() else {
            throw ToolError.notConfigured(
                toolName: displayName,
                reason: "Notes is disabled, or no vault/index is configured."
            )
        }

        guard let snapshot = try await dependencies.readCurrentSnapshot(path) else {
            throw ToolError.executionFailed(
                "Note \"\(path)\" doesn't exist. Use propose_note_create to create a new note."
            )
        }

        guard let vaultIDAfter = await dependencies.currentVaultID(), vaultIDAfter == vaultIDBefore else {
            throw ToolError.executionFailed(
                "The notes vault changed while preparing this proposal. Try again."
            )
        }
        let vaultID = vaultIDAfter

        try await MainActor.run {
            let proposal = NoteEditProposal(
                kind: .edit,
                notePath: path,
                baseContentHash: snapshot.sha256,
                proposedContent: content,
                summary: summary,
                chatID: chatID,
                originatingVaultID: vaultID
            )
            let context = ModelContext(modelContainer)
            context.insert(proposal)
            try context.save()
            coordinator.enqueue(proposalID: proposal.id, chatID: chatID)
        }

        return "Proposed edit to \(path) — awaiting user approval."
    }
}
