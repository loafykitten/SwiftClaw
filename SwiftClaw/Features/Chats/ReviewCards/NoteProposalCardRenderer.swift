import SwiftUI
import SwiftData

/// Note-proposal review-card renderer. Used by `ReviewCardRendererRegistry`
/// when a `ChatMessage` carries a `ReviewCardPayload` of type
/// `.noteProposal` — one card per `NoteEditProposal` (see
/// `NotesProposalCoordinator.drain`).
///
/// Reads live proposal state from `ModelContext` in `.task`, never from the
/// view `body` — the persisted `NoteEditProposal.status` (not the static
/// `ReviewCardPayload`) is the source of truth, so the row keeps reflecting
/// applied/rejected/conflicted state after the action, across relaunches,
/// without the card ever removing itself.
struct NoteProposalCardRenderer: View {
    let payload: ReviewCardPayload
    let dispatcher: AnyHashableReviewActionDispatcher

    @Environment(\.modelContext) private var modelContext

    @State private var proposal: NoteEditProposal?
    @State private var currentContent: String?
    @State private var isDiffExpanded = false
    @State private var isPerformingAction = false

    private var itemID: UUID? {
        payload.items.first?.itemID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let proposal {
                Text(proposal.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                pathLine(for: proposal)

                if proposal.kind != .rename {
                    diffDisclosure(for: proposal)
                }

                statusFooter(for: proposal)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.10))
        }
        .task(id: itemID) {
            await load()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.tint)
            Text(proposal.map { Self.title(for: $0.kind) } ?? "Note proposal")
                .font(.headline)
            Spacer()
        }
    }

    private static func title(for kind: NoteEditProposal.Kind) -> String {
        switch kind {
        case .create: "Create note"
        case .edit: "Edit note"
        case .append: "Append to note"
        case .rename: "Rename note"
        }
    }

    @ViewBuilder
    private func pathLine(for proposal: NoteEditProposal) -> some View {
        if proposal.kind == .rename, let newPath = proposal.newPath {
            Text("\(proposal.notePath) → \(newPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else {
            Text(proposal.notePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func diffDisclosure(for proposal: NoteEditProposal) -> some View {
        DisclosureGroup(isExpanded: $isDiffExpanded) {
            NoteProposalDiffView(lines: diffLines(for: proposal))
                .padding(.top, 4)
        } label: {
            Text(isDiffExpanded ? "Hide changes" : "Show changes")
                .font(.caption)
        }
    }

    private func diffLines(for proposal: NoteEditProposal) -> [DiffLine] {
        let base = currentContent ?? ""
        switch proposal.kind {
        case .create:
            return DiffEngine.diff(from: "", to: proposal.proposedContent ?? "")
        case .edit:
            return DiffEngine.diff(from: base, to: proposal.proposedContent ?? base)
        case .append:
            let appendText = proposal.appendText ?? ""
            let appended = proposal.proposedContent
                ?? (base.isEmpty ? appendText : base + "\n" + appendText)
            return DiffEngine.diff(from: base, to: appended)
        case .rename:
            return []
        }
    }

    @ViewBuilder
    private func statusFooter(for proposal: NoteEditProposal) -> some View {
        switch proposal.status {
        case .pending:
            HStack(spacing: 10) {
                Button("Reject", role: .destructive) {
                    perform(.reject, on: proposal)
                }
                .buttonStyle(.bordered)
                .disabled(isPerformingAction)

                Button("Approve") {
                    perform(.approve, on: proposal)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPerformingAction)
            }
        case .applying:
            VStack(alignment: .leading, spacing: 4) {
                statusBadge("Applying…", systemImage: "hourglass", color: .secondary)
                Text("This change may have been partially applied but its result couldn't be confirmed. Check the note directly, or ask me to re-propose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .applied:
            statusBadge("Applied", systemImage: "checkmark.circle.fill", color: .green)
        case .rejected:
            statusBadge("Rejected", systemImage: "xmark.circle.fill", color: .secondary)
        case .conflicted:
            VStack(alignment: .leading, spacing: 4) {
                statusBadge("Not applied — note changed", systemImage: "exclamationmark.triangle.fill", color: .orange)
                Text("This note changed after the proposal was made, so it wasn't applied. Ask me to re-propose the edit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .expired:
            VStack(alignment: .leading, spacing: 4) {
                statusBadge("Expired", systemImage: "clock.badge.xmark", color: .secondary)
                Text("The notes vault changed since this was proposed, so it wasn't applied. Ask me to re-propose the change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusBadge(_ label: String, systemImage: String, color: Color) -> some View {
        Label(label, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
    }

    private func perform(_ action: ReviewActionToken, on proposal: NoteEditProposal) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        let proposalID = proposal.id
        Task {
            await dispatcher.dispatcher.perform(action: action, itemID: proposalID)
            await reload(proposalID: proposalID)
            isPerformingAction = false
        }
    }

    private func load() async {
        guard let itemID else { return }
        await reload(proposalID: itemID)
    }

    private func reload(proposalID: UUID) async {
        proposal = Self.fetchLatestProposal(id: proposalID, in: modelContext)
        currentContent = nil
        guard let proposal,
              Self.canReadCurrentContent(
                  for: proposal,
                  currentVaultID: NotesFeatureModel.shared.configurationStore.vaultID,
                  isVaultAvailable: NotesFeatureModel.shared.isAvailableForReadTools
              ),
              let repository = NotesFeatureModel.shared.repository
        else { return }
        let path = proposal.notePath
        currentContent = try? await repository.read(relativePath: path).content
    }

    /// The current repository can only supply a valid diff base for a
    /// proposal from that same currently available vault. A switched or
    /// disabled vault leaves `currentContent` unset, so the card renders a
    /// safe proposed-content-only diff instead of reading unrelated content.
    static func canReadCurrentContent(
        for proposal: NoteEditProposal,
        currentVaultID: String?,
        isVaultAvailable: Bool
    ) -> Bool {
        isVaultAvailable
            && proposal.originatingVaultID != nil
            && proposal.originatingVaultID == currentVaultID
    }

    /// Fetches `id` through a **fresh** `ModelContext` built from the
    /// environment context's own `container`, rather than fetching directly
    /// on the (long-lived, shared-across-the-view-hierarchy) environment
    /// context passed in. Once a proposal is registered in a context, a
    /// plain `fetch` on that same context can return the already-registered
    /// instance's cached snapshot instead of picking up a write
    /// `NoteProposalDispatcher` just made through its own separate
    /// `ModelContext` — a fresh context has no such cache to go stale.
    /// The returned instance is read-only display state here (never mutated
    /// or saved through this context), so detachment from the environment
    /// context is safe. Internal (not private) so this exact fetch behavior
    /// is directly testable below the view layer.
    static func fetchLatestProposal(id: UUID, in modelContext: ModelContext) -> NoteEditProposal? {
        let freshContext = ModelContext(modelContext.container)
        var descriptor = FetchDescriptor<NoteEditProposal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? freshContext.fetch(descriptor).first
    }
}

/// Line-by-line current-vs-proposed diff body. Added/removed rows carry
/// explicit accessible labels ("Line added"/"Line removed") — the +/- marker
/// glyph and color aren't otherwise conveyed to VoiceOver.
private struct NoteProposalDiffView: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let lines: [DiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if lines.isEmpty {
                Text("No changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines) { line in
                    row(for: line)
                }
            }
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        }
    }

    private func row(for line: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker(for: line.kind))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color(for: line.kind))
            Text(line.content.isEmpty ? " " : line.content)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(background(for: line.kind))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NoteProposalDiffAccessibility.label(for: line))
    }

    private func marker(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .unchanged: " "
        case .added: "+"
        case .removed: "-"
        }
    }

    private func color(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .unchanged: .secondary
        case .added: colorSchemeContrast == .increased ? .primary : .green
        case .removed: colorSchemeContrast == .increased ? .primary : .red
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .unchanged: .clear
        case .added: Color.green.opacity(colorSchemeContrast == .increased ? 1 : 0.18)
        case .removed: Color.red.opacity(colorSchemeContrast == .increased ? 1 : 0.18)
        }
    }
}

enum NoteProposalDiffAccessibility {
    static func label(for line: DiffLine) -> String {
        let content = line.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            return switch line.kind {
            case .unchanged: "Blank line unchanged"
            case .added: "Blank line added"
            case .removed: "Blank line removed"
            }
        } else {
            return switch line.kind {
            case .unchanged: "Unchanged line: \(line.content)"
            case .added: "Line added: \(line.content)"
            case .removed: "Line removed: \(line.content)"
            }
        }
    }
}
