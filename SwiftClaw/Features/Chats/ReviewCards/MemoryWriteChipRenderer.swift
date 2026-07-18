import SwiftData
import SwiftUI

/// The disclosure chip for autonomous memory writes — "Memory added to *X*"
/// with **View** and one-tap **Undo** per written entry (plus text-only rows
/// for collections the AI created). Deliberately quieter than a proposal
/// card: these writes already happened; the chip's whole job is making them
/// impossible to miss and trivially reversible.
///
/// Live entry state comes from a fresh-context fetch (the
/// `NoteProposalCardRenderer` idiom) so Undo availability tracks the store:
/// once the entry is edited or superseded the button disables (undo would
/// destroy later work); once it's gone the row says so.
struct MemoryWriteChipRenderer: View {
    let payload: ReviewCardPayload
    let dispatcher: AnyHashableReviewActionDispatcher

    @Environment(\.modelContext) private var modelContext

    /// Live per-entry state keyed by `ReviewItem.itemID`.
    private enum EntryState {
        case undoable
        case lockedIn(reason: String)
        case removed
    }

    @State private var entryStates: [UUID: EntryState] = [:]
    @State private var performingItemIDs: Set<UUID> = []
    @State private var peekedEntryID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Memory updated", systemImage: "brain")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)

            ForEach(payload.items) { item in
                row(for: item)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        }
        .task(id: payload.items.map(\.itemID)) {
            reloadStates()
        }
        .sheet(
            isPresented: Binding(
                get: { peekedEntryID != nil },
                set: { if !$0 { peekedEntryID = nil } }
            )
        ) {
            if let peekedEntryID {
                MemoryEntryPeekSheet(entryID: peekedEntryID)
            }
        }
    }

    @ViewBuilder
    private func row(for item: ReviewItem) -> some View {
        if item.action == .undo {
            entryRow(for: item)
        } else {
            // Collection-creation rows are informational: the collection is
            // browsable in Memory; there is nothing to undo per-row.
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Created collection \"\(item.subject ?? "Untitled")\"")
                    .font(.callout)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func entryRow(for item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let subject = item.subject {
                Text("Added to \"\(subject)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.summary ?? "")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            footer(for: item)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func footer(for item: ReviewItem) -> some View {
        switch entryStates[item.itemID] ?? .undoable {
        case .undoable:
            HStack(spacing: 10) {
                Button("View") {
                    peekedEntryID = item.itemID
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("View this memory")

                Button("Undo") {
                    undo(item)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(performingItemIDs.contains(item.itemID))
                .accessibilityLabel("Undo saving this memory")
            }
        case .lockedIn(let reason):
            HStack(spacing: 10) {
                Button("View") {
                    peekedEntryID = item.itemID
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .removed:
            Label("No longer in memory", systemImage: "arrow.uturn.backward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func undo(_ item: ReviewItem) {
        guard performingItemIDs.insert(item.itemID).inserted else { return }
        Task {
            await dispatcher.dispatcher.perform(action: .undo, itemID: item.itemID)
            reloadStates()
            performingItemIDs.remove(item.itemID)
        }
    }

    private func reloadStates() {
        let freshContext = ModelContext(modelContext.container)
        var states: [UUID: EntryState] = [:]
        for item in payload.items where item.action == .undo {
            let id = item.itemID
            var descriptor = FetchDescriptor<MemoryEntry>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            guard let entry = try? freshContext.fetch(descriptor).first else {
                states[id] = .removed
                continue
            }
            states[id] = entry.isUndoableWrite
                ? .undoable
                : .lockedIn(reason: entry.supersededByID != nil
                    ? "Superseded since — undo is no longer available"
                    : "Edited since — undo is no longer available")
        }
        entryStates = states
    }
}

/// Read-only quick look at one entry from a chat chip — enough to judge the
/// write without leaving the conversation; editing lives in the Memory UI.
private struct MemoryEntryPeekSheet: View {
    let entryID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var entry: MemoryEntry?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Memory") {
                dismiss()
            }
            List {
                if let entry {
                    Section {
                        Text(entry.body)
                            .font(.body)
                            .textSelection(.enabled)
                        if !entry.tags.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(entry.tags, id: \.self) { tag in
                                    MemoryChip(text: tag)
                                }
                            }
                        }
                    }
                    if let collection = entry.collection {
                        Section("Collection") {
                            HStack {
                                Label(collection.title, systemImage: collection.isInbox ? "tray" : "folder")
                                Spacer(minLength: 4)
                                MemoryAccessBadge(accessLevel: collection.accessLevel)
                            }
                        }
                    }
                    Section {
                        Text("Open Memory in Workspace to edit or move this entry.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView(
                        "No Longer in Memory",
                        systemImage: "brain",
                        description: Text("This entry was removed.")
                    )
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 320)
        #endif
        .task {
            let freshContext = ModelContext(modelContext.container)
            let id = entryID
            var descriptor = FetchDescriptor<MemoryEntry>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            entry = try? freshContext.fetch(descriptor).first
        }
    }
}
