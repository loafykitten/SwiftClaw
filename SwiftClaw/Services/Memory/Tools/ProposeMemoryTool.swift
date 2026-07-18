import Foundation
import SwiftData

nonisolated extension MemoryProposal.Source {
    /// The review-service provenance for proposals raised while reviewing
    /// `feature`. Memory itself has no review service.
    init?(reviewing feature: WorkspaceFeature) {
        switch feature {
        case .email: self = .emailReview
        case .calendar: self = .calendarReview
        case .reminders: self = .remindersReview
        case .notes: self = .notesReview
        case .memory: return nil
        }
    }
}

/// Per-run record of the proposals a review pass raised, so the service can
/// route their cards into the run's review chat afterwards (the
/// `NotesReviewFindingCollector` pattern). Also the seat of the hard cap.
@MainActor
final class MemoryProposalRunCollector {
    private(set) var proposalIDs: [UUID] = []

    nonisolated init() {}

    func record(_ id: UUID) {
        proposalIDs.append(id)
    }
}

/// `propose_memory` — the background review services' only path into
/// memory. System-only: constructed per run into each service's scoped
/// `ToolRegistry(tools:)`, never registered on `ToolRegistry.shared`, so
/// user chats can't invoke it (they have the richer write tools).
///
/// Proposes a finished artifact — exact entry text, target collection or
/// new-collection request, tags, and the reason shown on the card — as a
/// durable `MemoryProposal`; it never writes an entry directly. Restraint
/// is cap-enforced here (max 2 per run), not just prompted; the injected
/// memory context doubles as dedup since the model sees what already exists
/// and what was previously declined before proposing.
final class ProposeMemoryTool: Tool {
    static let maxProposalsPerRun = 2

    let name = "propose_memory"
    let displayName = "Propose Memory"
    let description = """
        Propose saving one short fact (15-40 tokens) to the user's \
        persistent memory. Gated behind the user's explicit approval — \
        nothing is saved until they accept. Use at most \
        \(maxProposalsPerRun) times per review, and only for durable \
        preferences or patterns worth carrying into future reviews — never \
        for one-off facts, and never for anything listed as previously \
        declined.
        """
    let systemImage = "brain.head.profile"

    let parameters = [
        ToolParameter(
            name: "content",
            type: .string,
            description: "The exact fact to remember — one atomic statement.",
            isRequired: true
        ),
        ToolParameter(
            name: "reason",
            type: .string,
            description: "One sentence for the review card: why this is worth remembering.",
            isRequired: true
        ),
        ToolParameter(
            name: "collection",
            type: .string,
            description: "Existing target collection (title or 8-character handle from the memory context). Omit to file into the Inbox."
        ),
        ToolParameter(
            name: "new_collection_title",
            type: .string,
            description: "Ask for a new collection with this title instead of an existing one."
        ),
        ToolParameter(
            name: "tags",
            type: .array,
            description: "Optional cross-cutting tags."
        ),
    ]

    private let feature: WorkspaceFeature
    private let modelContainer: ModelContainer
    private let collector: MemoryProposalRunCollector
    private let dependencies: MemoryWriteToolDependencies

    @MainActor
    init(
        feature: WorkspaceFeature,
        modelContainer: ModelContainer,
        collector: MemoryProposalRunCollector,
        dependencies: MemoryWriteToolDependencies = .live
    ) {
        self.feature = feature
        self.modelContainer = modelContainer
        self.collector = collector
        self.dependencies = dependencies
    }

    var isConfigured: Bool {
        MainActor.assumeIsolated { dependencies.isAvailable() }
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let content = arguments["content"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw ToolError.missingArgument("content")
        }
        guard let reason = arguments["reason"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else {
            throw ToolError.missingArgument("reason")
        }
        let collectionReference = arguments["collection"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newCollectionTitle = arguments["new_collection_title"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Mutually exclusive: the card renders a new-collection proposal
        // whenever a title is present, so a proposal carrying both would
        // show one target and apply to the other on acceptance.
        if collectionReference?.isEmpty == false, newCollectionTitle?.isEmpty == false {
            throw ToolError.invalidArguments(
                "Pass either \"collection\" or \"new_collection_title\", not both."
            )
        }
        let tags = MemoryToolArguments.tags(from: arguments)
        guard let source = MemoryProposal.Source(reviewing: feature) else {
            throw ToolError.executionFailed("propose_memory is not available for this feature.")
        }

        return try await MainActor.run {
            guard dependencies.isAvailable(), let repository = dependencies.repository() else {
                throw ToolError.notConfigured(toolName: displayName, reason: SearchMemoryTool.unavailableReason)
            }
            guard collector.proposalIDs.count < Self.maxProposalsPerRun else {
                throw ToolError.executionFailed(
                    "Proposal cap reached (\(Self.maxProposalsPerRun) per review). Do not call propose_memory again this run."
                )
            }

            var targetCollectionID: UUID?
            if let collectionReference, !collectionReference.isEmpty {
                guard let target = try? OpenMemoryCollectionTool.Dependencies.resolveCollection(
                    reference: collectionReference,
                    repository: repository
                ) else {
                    throw ToolError.invalidArguments("""
                        No collection matches "\(collectionReference)". Use a title or handle \
                        from the memory context, pass new_collection_title, or omit \
                        "collection" to file into the Inbox.
                        """)
                }
                targetCollectionID = target.id
            }

            let proposal = MemoryProposal(
                entryText: content,
                targetCollectionID: targetCollectionID,
                newCollectionTitle: newCollectionTitle?.isEmpty == true ? nil : newCollectionTitle,
                newCollectionAccessLevel: nil,
                scope: newCollectionTitle == nil ? nil : feature,
                tags: tags,
                summary: reason,
                source: source
            )
            let context = ModelContext(modelContainer)
            context.insert(proposal)
            try context.save()
            collector.record(proposal.id)
            return "Proposed — the user will see an approval card. (\(collector.proposalIDs.count)/\(Self.maxProposalsPerRun) this run.)"
        }
    }
}
