import SwiftUI

/// Trailing inspector: every note that links to the currently selected note.
/// Reads `NotesFeatureModel.backlinks`/`isLoadingBacklinks`/
/// `backlinksError` (kept fresh by the model on selection change and on
/// reconcile deltas that touch the selection) rather than querying the
/// indexer itself, so this view never depends on `NotesIndexer` directly.
struct BacklinksPanel: View {
    let model: NotesFeatureModel
    /// Compact Notes supplies this so choosing a backlink can push the new
    /// detail view. The regular layouts keep their selection-driven columns.
    let onSelectPath: ((String) -> Void)?
    /// iOS inspectors can adapt to a sheet, where a visible close control is
    /// needed. The macOS trailing pane leaves this nil.
    let onDismiss: (() -> Void)?

    init(
        model: NotesFeatureModel,
        onSelectPath: ((String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.model = model
        self.onSelectPath = onSelectPath
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Backlinks")
                    .font(.headline)
                Spacer()
                if let onDismiss {
                    Button("Done", action: onDismiss)
                }
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)

            Divider()

            content
        }
        .frame(minWidth: 240, idealWidth: 280)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.backlinksError {
            errorState(error)
        } else if model.isLoadingBacklinks, model.backlinks.isEmpty {
            ProgressView("Loading backlinks…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.backlinks.isEmpty {
            emptyState
        } else {
            List(Array(model.backlinks.enumerated()), id: \.offset) { _, link in
                Button {
                    if let onSelectPath {
                        onSelectPath(link.sourcePath)
                    } else {
                        Task { await model.select(path: link.sourcePath) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NoteSummary.title(forRelativePath: link.sourcePath))
                            .font(.body)
                        Text(link.sourcePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let context = contextLabel(for: link) {
                            Text(context)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: link))
            }
            .listStyle(.sidebar)
        }
    }

    private var emptyState: some View {
        FeaturePlaceholderView(
            systemImage: "link",
            title: "No Backlinks",
            message: "No other notes link to this one yet."
        )
    }

    private func errorState(_ error: NotesError) -> some View {
        FeaturePlaceholderView(
            systemImage: "exclamationmark.triangle",
            title: "Couldn't Load Backlinks",
            message: error.errorDescription ?? "An unknown error occurred."
        )
        .accessibilityLabel("Couldn't load backlinks: \(error.errorDescription ?? "An unknown error occurred.")")
    }

    private func contextLabel(for link: ResolvedLink) -> String? {
        switch (link.alias, link.heading) {
        case (let alias?, let heading?): "\"\(alias)\" § \(heading)"
        case (let alias?, nil): "\"\(alias)\""
        case (nil, let heading?): "§ \(heading)"
        case (nil, nil): nil
        }
    }

    private func accessibilityLabel(for link: ResolvedLink) -> String {
        let title = NoteSummary.title(forRelativePath: link.sourcePath)
        if let context = contextLabel(for: link) {
            return "\(title), \(context)"
        }
        return title
    }
}
