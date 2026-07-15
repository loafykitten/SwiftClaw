import Foundation
import SwiftData

/// Proposes creating a brand-new note. **Never writes the vault** — inserts
/// a `pending` `NoteEditProposal` (`baseContentHash == nil`, meaning
/// create-only at approve time) into the chat's `ModelContainer` and queues
/// its id on `NotesProposalCoordinator`. See `ProposeNoteEditTool` for the
/// shared shape/rationale; this tool is create-only and refuses to propose
/// over a path that already exists.
struct ProposeNoteCreateTool: Tool {
    /// Mirrors `ProposeNoteEditTool.Dependencies` — a `nil` snapshot means
    /// "nothing exists at this path yet", which is what a create proposal
    /// requires.
    struct Dependencies: Sendable {
        var isAvailable: @MainActor @Sendable () -> Bool
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
                    if case .notConfigured = toolError { throw toolError }
                    return nil
                }
            }
        )
    }

    let name = "propose_note_create"
    let displayName = "Propose Note Create"
    let description = """
        Propose creating a brand-new note at a vault-relative path. This is \
        gated behind explicit user approval — it never modifies the vault \
        directly, and it will not overwrite a note that already exists at \
        that path. Use propose_note_edit instead to change an existing note.
        """
    let systemImage = "doc.badge.plus"

    let parameters = [
        ToolParameter(
            name: "path",
            type: .string,
            description: "Vault-relative path for the new note, e.g. \"folder/New Note.md\". Must not already exist.",
            isRequired: true
        ),
        ToolParameter(
            name: "content",
            type: .string,
            description: "The new note's full content.",
            isRequired: true
        ),
        ToolParameter(
            name: "summary",
            type: .string,
            description: "A short, one-sentence human-readable summary of the note being created, shown on the review card.",
            isRequired: true
        ),
    ]

    private let modelContainer: ModelContainer
    private let chatID: UUID
    private let coordinator: NotesProposalCoordinator
    private let dependencies: Dependencies

    /// `@MainActor` — see `ProposeNoteEditTool.init` for why this replaces a
    /// nonisolated init body's `MainActor.assumeIsolated` runtime trap with a
    /// compiler-enforced call-site contract every real caller already meets.
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

        // Same before/after vault-identity capture as `ProposeNoteEditTool`
        // — see its `execute` for the full rationale.
        guard let vaultIDBefore = await dependencies.currentVaultID() else {
            throw ToolError.notConfigured(
                toolName: displayName,
                reason: "Notes is disabled, or no vault/index is configured."
            )
        }

        if try await dependencies.readCurrentSnapshot(path) != nil {
            throw ToolError.invalidArguments(
                "A note already exists at \"\(path)\". Use propose_note_edit to change it instead."
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
                kind: .create,
                notePath: path,
                baseContentHash: nil,
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

        return "Proposed creating \(path) — awaiting user approval."
    }
}
