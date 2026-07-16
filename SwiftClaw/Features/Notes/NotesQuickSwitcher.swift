import SwiftUI

/// Fuzzy-ranked, keyboard-friendly quick switcher for jumping straight to a
/// note by title. Scoped to Notes for v1 (per `docs/NOTES_PLAN.md`
/// cross-feature #4, a follow-up app-global Cmd-K switcher can reuse
/// `FuzzyMatcher` unchanged) — this view only ever touches
/// `NotesFeatureModel`. Presented as a sheet from `NotesView`, opened with
/// `Cmd-O`.
struct NotesQuickSwitcher: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let model: NotesFeatureModel
    /// Optional compact-width routing hook. The regular layouts retain their
    /// selection-driven detail column, while compact Notes needs to push onto
    /// Workspace's ambient navigation stack after a switcher choice.
    let onSelectPath: ((String) -> Void)?
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selectedPath: String?
    @FocusState private var isSearchFieldFocused: Bool

    private var ranked: [NotesQuickSwitcherRanking.Result] {
        NotesQuickSwitcherRanking.rank(query: query, notes: model.notes)
    }

    var body: some View {
        Group {
            #if os(macOS)
            switcherContent
                .frame(width: 480)
            #else
            if usesCompactSheet {
                NavigationStack {
                    switcherContent
                        .navigationTitle("Quick Switcher")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done", action: onDismiss)
                            }
                        }
                }
            } else {
                switcherContent
                    .frame(width: 480)
            }
            #endif
        }
        .onAppear {
            isSearchFieldFocused = true
            selectedPath = ranked.first?.note.relativePath
        }
        .onChange(of: query) {
            selectedPath = NotesQuickSwitcherSelection.validSelection(
                selectedPath,
                in: ranked.map(\.note.relativePath)
            )
        }
        #if os(macOS)
        .onExitCommand { onDismiss() }
        #endif
    }

    @ViewBuilder
    private var switcherContent: some View {
        if usesCompactSheet {
            switcherBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            switcherBody
        }
    }

    private var switcherBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Jump to note…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .onKeyPress { keyPress in
                        handleKeyPress(keyPress)
                    }
                    .onSubmit { selectHighlightedOrFirst() }
                    .accessibilityLabel("Search notes to jump to")
            }
            .padding(10)

            Divider()

            if ranked.isEmpty {
                FeaturePlaceholderView(
                    systemImage: "note.text",
                    title: query.isEmpty ? "Type to search" : "No matches",
                    message: query.isEmpty ? "Start typing a note title." : "No notes match \"\(query)\"."
                )
                .frame(height: 160)
            } else {
                if usesCompactSheet {
                    resultsList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    resultsList
                        .frame(height: 280)
                }
            }
        }
    }

    private var resultsList: some View {
        List(ranked, id: \.note.relativePath, selection: $selectedPath) { result in
            Button {
                choose(result.note)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.note.title)
                        .font(.body)
                    Text(result.note.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .tag(result.note.relativePath)
            .accessibilityLabel("\(result.note.title), \(result.note.relativePath)")
            .accessibilityHint("Opens this note")
        }
    }

    private var usesCompactSheet: Bool {
        #if os(macOS)
        false
        #else
        horizontalSizeClass == .compact
        #endif
    }

    private func selectHighlightedOrFirst() {
        let target = ranked.first { $0.note.relativePath == selectedPath }?.note ?? ranked.first?.note
        guard let target else { return }
        choose(target)
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        let paths = ranked.map(\.note.relativePath)

        switch keyPress.key {
        case .upArrow:
            selectedPath = NotesQuickSwitcherSelection.move(.up, from: selectedPath, in: paths)
            return .handled
        case .downArrow:
            selectedPath = NotesQuickSwitcherSelection.move(.down, from: selectedPath, in: paths)
            return .handled
        case .return:
            selectHighlightedOrFirst()
            return .handled
        case .escape:
            onDismiss()
            return .handled
        default:
            return .ignored
        }
    }

    private func choose(_ note: NoteSummary) {
        if let onSelectPath {
            onSelectPath(note.relativePath)
            onDismiss()
            return
        }
        Task {
            await model.select(path: note.relativePath)
            onDismiss()
        }
    }
}

/// Pure selection policy for keyboard navigation. Keeping this separate from
/// SwiftUI makes stale-selection and empty-result behavior deterministic.
enum NotesQuickSwitcherSelection {
    enum Direction {
        case up
        case down
    }

    static func validSelection(_ selectedPath: String?, in paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        if let selectedPath, paths.contains(selectedPath) {
            return selectedPath
        }
        return paths.first
    }

    static func move(_ direction: Direction, from selectedPath: String?, in paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        guard let selectedPath, let index = paths.firstIndex(of: selectedPath) else {
            return paths.first
        }

        switch direction {
        case .up:
            return paths[max(paths.startIndex, index - 1)]
        case .down:
            return paths[min(paths.index(before: paths.endIndex), index + 1)]
        }
    }
}

/// Pure fuzzy-ranking logic behind the switcher — separated out so it's
/// directly testable without instantiating any SwiftUI view. An empty query
/// lists every note alphabetically (a browsable "recent/all notes" default,
/// matching `FuzzyMatcher.match`'s documented no-match-on-empty-query
/// behavior) rather than showing nothing until the user types.
enum NotesQuickSwitcherRanking {
    struct Result: Equatable {
        let note: NoteSummary
        let match: FuzzyMatcher.Match?
    }

    static func rank(query: String, notes: [NoteSummary]) -> [Result] {
        guard !query.isEmpty else {
            return notes
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { Result(note: $0, match: nil) }
        }
        return notes
            .compactMap { note -> Result? in
                guard let match = FuzzyMatcher.match(query: query, in: note.title) else { return nil }
                return Result(note: note, match: match)
            }
            .sorted { lhs, rhs in
                guard let lhsScore = lhs.match?.score, let rhsScore = rhs.match?.score, lhsScore != rhsScore else {
                    return lhs.note.title.localizedCaseInsensitiveCompare(rhs.note.title) == .orderedAscending
                }
                return lhsScore > rhsScore
            }
    }
}
