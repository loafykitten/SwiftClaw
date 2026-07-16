import SwiftUI

/// Minimal history browser for one live note. Revisions stay private outside
/// the vault; restoring always creates a visible sibling conflict copy so the
/// current note can never be silently replaced by older content.
struct NoteRevisionsSheet: View {
    let relativePath: String
    let model: NotesFeatureModel
    let onDismiss: () -> Void

    @State private var revisions: [NoteRevision] = []
    @State private var isLoading = true
    @State private var loadError: NotesError?
    @State private var actionError: NotesError?
    @State private var restoringRevisionID: String?
    @State private var restoredPath: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading revisions…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't Load Revisions", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError.errorDescription ?? "An unknown error occurred.")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if revisions.isEmpty {
                    ContentUnavailableView(
                        "No Revisions Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("A revision is saved before each edit, rename, or delete.")
                    )
                } else {
                    revisionList
                }
            }
            .navigationTitle("Revisions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
        .task(id: relativePath) { await load() }
    }

    private var revisionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                Text(relativePath)
                    .font(.body)
                    .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let restoredPath {
                    Label("Restored as \(restoredPath)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Revision restored as a separate copy named \(restoredPath)")
                }

                if let actionError {
                    Label(
                        actionError.errorDescription ?? "The revision couldn't be restored.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                    .accessibilityLabel(
                        "Revision restore failed: \(actionError.errorDescription ?? "An unknown error occurred.")"
                    )
                }

                ForEach(revisions) { revision in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(revision.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.headline)
                        Divider()
                    revisionPreviewRow(revision)
                    restoreButton(for: revision)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: .rect(cornerRadius: 10))
                }
            }
            .padding()
        }
    }

    private func revisionPreviewRow(_ revision: NoteRevision) -> some View {
        let preview = Self.preview(for: revision.content)
        return Text(preview)
            .font(.body.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Revision preview: \(preview)")
    }

    private func restoreButton(for revision: NoteRevision) -> some View {
        Button {
            Task { await restore(revision) }
        } label: {
            if restoringRevisionID == revision.id {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Restoring…")
                }
            } else {
                Label("Restore as Copy", systemImage: "doc.on.doc")
            }
        }
        .buttonStyle(.bordered)
        .disabled(restoringRevisionID != nil)
        .accessibilityLabel(
            restoringRevisionID == revision.id
                ? "Restoring revision from \(revision.createdAt.formatted(date: .abbreviated, time: .shortened))"
                : "Restore revision from \(revision.createdAt.formatted(date: .abbreviated, time: .shortened)) as a separate copy"
        )
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            revisions = try await model.revisions(forRelativePath: relativePath)
        } catch {
            revisions = []
            loadError = NotesError.from(error)
        }
        isLoading = false
    }

    private func restore(_ revision: NoteRevision) async {
        guard restoringRevisionID == nil else { return }
        restoringRevisionID = revision.id
        actionError = nil
        restoredPath = nil
        defer { restoringRevisionID = nil }

        do {
            let restored = try await model.restoreRevisionAsConflictCopy(
                relativePath: relativePath,
                revisionID: revision.id
            )
            restoredPath = restored.relativePath
        } catch {
            actionError = NotesError.from(error)
        }
    }

    private static func preview(for content: String) -> String {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Empty note" }
        let prefix = String(normalized.prefix(240))
        return prefix.count == normalized.count ? prefix : prefix + "…"
    }
}
