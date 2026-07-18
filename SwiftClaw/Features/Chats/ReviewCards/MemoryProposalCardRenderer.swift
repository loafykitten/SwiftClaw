import SwiftData
import SwiftUI

/// Inline memory-proposal card: the finished artifact (exact entry text,
/// target collection or new-collection request, tags) with **Accept /
/// Edit / Dismiss**. Edit opens a prefilled sheet; saving there is
/// accept-with-modified-text (the sheet persists the edited `entryText`
/// first, then dispatches the same `.approve` the Accept button uses).
///
/// Live proposal state comes from a fresh-context fetch (the
/// `NoteProposalCardRenderer` idiom): the persisted `MemoryProposal.status`
/// is the source of truth, so the card keeps showing applied/dismissed
/// state across relaunches without removing itself.
struct MemoryProposalCardRenderer: View {
    let payload: ReviewCardPayload
    let dispatcher: AnyHashableReviewActionDispatcher

    @Environment(\.modelContext) private var modelContext

    @State private var proposal: MemoryProposal?
    @State private var isPerformingAction = false
    @State private var isEditing = false

    private var itemID: UUID? {
        payload.items.first?.itemID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .foregroundStyle(.tint)
                Text(proposal?.newCollectionTitle != nil ? "New memory collection proposed" : "Memory proposed")
                    .font(.headline)
                Spacer()
            }

            if let proposal {
                Text(proposal.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                entryTextBlock(for: proposal)
                targetLine(for: proposal)

                if !proposal.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(proposal.tags, id: \.self) { tag in
                            MemoryChip(text: tag)
                        }
                    }
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
            reload()
        }
        .sheet(isPresented: $isEditing) {
            if let proposal {
                MemoryProposalEditSheet(
                    proposalID: proposal.id,
                    initialText: proposal.entryText,
                    isSeedList: proposal.newCollectionTitle != nil
                ) {
                    // Saving the sheet = accept with the modified text.
                    perform(.approve)
                }
            }
        }
    }

    @ViewBuilder
    private func entryTextBlock(for proposal: MemoryProposal) -> some View {
        let texts = MemoryProposalDispatcher.entryTexts(for: proposal)
        if !texts.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(texts.enumerated()), id: \.offset) { _, text in
                    Text("• \(text)")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06))
            }
        }
    }

    @ViewBuilder
    private func targetLine(for proposal: MemoryProposal) -> some View {
        if let title = proposal.newCollectionTitle {
            HStack(spacing: 5) {
                Label("New collection: \(title)", systemImage: "folder.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MemoryAccessBadge(accessLevel: proposal.newCollectionAccessLevel ?? .writesFreely)
            }
        } else if let subject = payload.items.first?.subject {
            Label("Into \"\(subject)\"", systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusFooter(for proposal: MemoryProposal) -> some View {
        switch proposal.status {
        case .pending:
            HStack(spacing: 10) {
                Button("Dismiss", role: .destructive) {
                    perform(.reject)
                }
                .buttonStyle(.bordered)
                .disabled(isPerformingAction)
                .accessibilityLabel("Dismiss this memory proposal")

                Button("Edit") {
                    isEditing = true
                }
                .buttonStyle(.bordered)
                .disabled(isPerformingAction)
                .accessibilityLabel("Edit this memory proposal before accepting")

                Button("Accept") {
                    perform(.approve)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPerformingAction)
                .accessibilityLabel("Accept and save this memory")
            }
        case .applying:
            VStack(alignment: .leading, spacing: 4) {
                statusBadge("Applying…", systemImage: "hourglass", color: .secondary)
                Text("This may have been saved but its result couldn't be confirmed. Check Memory directly, or ask me to propose it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .applied:
            statusBadge("Saved to memory", systemImage: "checkmark.circle.fill", color: .green)
        case .rejected:
            statusBadge("Dismissed", systemImage: "xmark.circle.fill", color: .secondary)
        case .expired:
            statusBadge("Expired", systemImage: "clock.badge.xmark", color: .secondary)
        }
    }

    private func statusBadge(_ label: String, systemImage: String, color: Color) -> some View {
        Label(label, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
    }

    private func perform(_ action: ReviewActionToken) {
        guard !isPerformingAction, let itemID else { return }
        isPerformingAction = true
        Task {
            await dispatcher.dispatcher.perform(action: action, itemID: itemID)
            reload()
            isPerformingAction = false
        }
    }

    private func reload() {
        guard let itemID else { return }
        let freshContext = ModelContext(modelContext.container)
        var descriptor = FetchDescriptor<MemoryProposal>(predicate: #Predicate { $0.id == itemID })
        descriptor.fetchLimit = 1
        proposal = try? freshContext.fetch(descriptor).first
    }
}

/// The card's Edit sheet. Saving persists the modified `entryText` through
/// its own fresh context, then hands control back to the card, which
/// dispatches `.approve` — so an edited acceptance follows exactly the same
/// approval path as an untouched one.
private struct MemoryProposalEditSheet: View {
    let proposalID: UUID
    let initialText: String
    /// New-collection proposals hold one seed fact per line.
    let isSeedList: Bool
    let onSaveAndAccept: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var text = ""
    @State private var hasLoaded = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Edit Memory") {
                dismiss()
            }
            Form {
                Section {
                    TextField("Memory", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                } footer: {
                    Text(isSeedList
                        ? "One fact per line. Saving accepts the proposal with your wording."
                        : "Saving accepts the proposal with your wording.")
                }
                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            SheetFooter(
                confirmTitle: "Save & Accept",
                isDisabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSeedList
            ) {
                saveAndAccept()
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 280)
        #endif
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            text = initialText
        }
    }

    private func saveAndAccept() {
        let context = ModelContext(modelContext.container)
        let id = proposalID
        var descriptor = FetchDescriptor<MemoryProposal>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let proposal = try? context.fetch(descriptor).first else {
            // Resolved elsewhere while the sheet was open — the card's own
            // reload will show the terminal state; nothing to accept here.
            dismiss()
            return
        }
        guard proposal.status == .pending else {
            dismiss()
            return
        }
        proposal.entryText = text
        do {
            try context.save()
        } catch {
            // Approving now would silently accept the *original* wording.
            // Keep the sheet open so the user's edit isn't quietly dropped.
            saveError = "Couldn't save your wording. Try again."
            return
        }
        dismiss()
        onSaveAndAccept()
    }
}
