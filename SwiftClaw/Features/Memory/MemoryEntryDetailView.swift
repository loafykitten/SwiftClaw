import SwiftData
import SwiftUI

/// One entry, fully spelled out: body, tags, home collection with its access
/// badge, provenance, and the user's full-control actions (edit in place,
/// move, delete). Deletes are confirmation-gated (destructive), edits are
/// not (freely reversible by editing again).
struct MemoryEntryDetailView: View {
    let entry: MemoryEntry
    let repository: MemoryRepository

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MemoryCollection.createdAt) private var collections: [MemoryCollection]
    @State private var isEditing = false
    @State private var isConfirmingDelete = false

    var body: some View {
        List {
            if entry.supersededByID != nil {
                Section {
                    Label(
                        "A newer entry superseded this fact. It stays visible for history.",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

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

            Section("History") {
                LabeledContent(
                    entry.createdBy == .ai ? "Added by the AI" : "Added by you",
                    value: entry.createdAt.formatted(date: .abbreviated, time: .shortened)
                )
                if entry.updatedAt != entry.createdAt {
                    LabeledContent(
                        "Last changed",
                        value: entry.updatedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                LabeledContent("Handle", value: entry.handle)
                    .accessibilityLabel("Handle \(entry.handle)")
            }
        }
        .navigationTitle("Memory")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isEditing = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    moveMenu
                    Divider()
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("Entry Actions", systemImage: "ellipsis.circle")
                }
                .accessibilityLabel("Entry actions")
            }
        }
        .sheet(isPresented: $isEditing) {
            MemoryEntryEditorSheet(mode: .edit(entry), repository: repository, collections: collections)
        }
        .confirmationDialog(
            "Delete this memory?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Memory", role: .destructive) {
                repository.deleteEntry(entry, actor: .user)
                dismiss()
            }
        } message: {
            Text("The entry is removed from memory. The activity feed keeps a record of what it said.")
        }
    }

    private var moveMenu: some View {
        Menu {
            ForEach(collections.filter { $0.id != entry.collection?.id }) { collection in
                Button(collection.title) {
                    repository.moveEntry(entry, to: collection, actor: .user)
                }
            }
        } label: {
            Label("Move To", systemImage: "folder")
        }
    }
}
