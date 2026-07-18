import Foundation
import SwiftData

/// Builds the memory block a background review service concatenates into
/// its standalone system prompt — the payoff of collection scoping: a
/// small, targeted context instead of the whole store in every
/// fresh-context run.
///
/// Read recipe (per `docs/features/MEMORY.md`): every pinned collection
/// (regardless of scope) + collections scoped to the reviewed feature.
/// Nothing else. The block ends with recent *declined* proposal texts for
/// this feature — the injected text is the re-proposal dedup ("no" must not
/// become a weekly question).
@MainActor
enum MemoryReviewContextBuilder {
    static let declinedProposalLimit = 20

    /// nil when Memory is disabled/unconfigured or there is nothing to
    /// inject (no matching collections and no declined proposals).
    static func block(
        for feature: WorkspaceFeature,
        repository: MemoryRepository? = MemoryFeatureModel.shared.repository,
        isEnabled: Bool = SettingsStorage.isMemoryEnabled()
    ) -> String? {
        guard isEnabled, let repository else { return nil }

        let all = repository.collections()
        let pinned = all.filter(\.isPinned)
        let scoped = all.filter { !$0.isPinned && $0.scope == feature }
        let included = pinned + scoped
        let declined = declinedProposalTexts(for: feature, repository: repository)
        guard !included.isEmpty || !declined.isEmpty else { return nil }

        var lines: [String] = [
            "## Memory",
            "",
            """
            The user's persistent memory relevant to this review: pinned \
            collections plus collections scoped to \(feature.displayName). \
            Apply these facts; they already exist, so never re-propose them. \
            If this review reveals a durable pattern worth keeping, you may \
            use propose_memory (max \(ProposeMemoryTool.maxProposalsPerRun) \
            per review) — the user approves or dismisses each proposal. \
            \(MemoryPromptBuilder.untrustedContentNotice)
            """,
        ]
        for collection in included {
            lines.append("")
            lines.append(contentsOf: MemoryPromptBuilder.serialize(collection: collection))
        }
        if !declined.isEmpty {
            lines.append("")
            lines.append("### Previously declined proposals — do not re-propose these or close variants")
            for text in declined {
                lines.append("- \(MemoryPromptBuilder.sanitized(text))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Recent rejected proposals attributable to this feature: raised by its
    /// review service, or explicitly scoped to it.
    private static func declinedProposalTexts(
        for feature: WorkspaceFeature,
        repository: MemoryRepository
    ) -> [String] {
        guard let source = MemoryProposal.Source(reviewing: feature) else { return [] }
        let rejectedRawValue = MemoryProposal.Status.rejected.rawValue
        let sourceRawValue = source.rawValue
        let scopeRawValue: String? = feature.rawValue
        var descriptor = FetchDescriptor<MemoryProposal>(
            predicate: #Predicate {
                $0.statusRawValue == rejectedRawValue
                    && ($0.sourceRawValue == sourceRawValue || $0.scopeRawValue == scopeRawValue)
            },
            sortBy: [SortDescriptor(\.resolvedAt, order: .reverse)]
        )
        descriptor.fetchLimit = declinedProposalLimit
        let rejected = (try? repository.modelContext.fetch(descriptor)) ?? []
        return rejected.map(\.entryText).filter { !$0.isEmpty }
    }
}
