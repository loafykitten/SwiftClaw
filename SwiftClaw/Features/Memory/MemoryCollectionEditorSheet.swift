import SwiftUI

/// Create or edit a memory collection. The asksFirst → writesFreely switch
/// is confirmation-gated here (loosening supervision is one of the
/// always-confirm operations); tightening to asksFirst applies directly.
/// The built-in Inbox never reaches this sheet — its edit affordances are
/// disabled at the call sites.
struct MemoryCollectionEditorSheet: View {
    enum Mode {
        case create
        case edit(MemoryCollection)
    }

    let mode: Mode
    let repository: MemoryRepository

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var tagsText = ""
    @State private var accessLevel: MemoryCollection.AccessLevel = .writesFreely
    @State private var scope: WorkspaceFeature?
    @State private var isPinned = false
    @State private var hasLoaded = false
    @State private var isConfirmingLoosenedAccess = false
    @State private var saveError: String?

    /// Feature scopes a collection can target: the features whose review
    /// services consume scoped memory. Memory itself is deliberately absent
    /// — a collection scoped to Memory would mean nothing.
    static let scopeOptions: [WorkspaceFeature] = [.email, .calendar, .reminders, .notes]

    private var sheetTitle: String {
        switch mode {
        case .create: "New Collection"
        case .edit: "Edit Collection"
        }
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether saving would loosen supervision on an existing collection.
    private var loosensAccess: Bool {
        guard case .edit(let collection) = mode else { return false }
        return collection.accessLevel == .asksFirst && accessLevel == .writesFreely
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: sheetTitle) {
                dismiss()
            }

            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text("What this collection holds"))
                    TextField("Details", text: $details, axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Tags", text: $tagsText, prompt: Text("Comma-separated"))
                }

                Section {
                    Picker("AI access", selection: $accessLevel) {
                        ForEach(MemoryCollection.AccessLevel.allCases, id: \.self) { level in
                            Label(
                                MemoryAccessPresentation.label(for: level),
                                systemImage: MemoryAccessPresentation.systemImage(for: level)
                            )
                            .tag(level)
                        }
                    }
                    .accessibilityLabel("AI access level")
                } footer: {
                    Text(accessLevel == .asksFirst
                        ? "Every AI write to this collection needs your approval first."
                        : "AI writes land immediately, disclosed in chat with one-tap undo.")
                }

                Section {
                    Picker("Scope", selection: $scope) {
                        Text("Global").tag(WorkspaceFeature?.none)
                        ForEach(Self.scopeOptions) { feature in
                            Label(feature.displayName, systemImage: feature.systemImage)
                                .tag(Optional(feature))
                        }
                    }
                    Toggle("Pinned", isOn: $isPinned)
                } footer: {
                    Text("Scoped collections ride along into that feature's background reviews. Pinned collections are always in context.")
                }

                if let saveError {
                    MemorySaveErrorSection(message: saveError)
                }
            }
            .formStyle(.grouped)

            SheetFooter(confirmTitle: "Save", isDisabled: !isValid) {
                if loosensAccess {
                    isConfirmingLoosenedAccess = true
                } else {
                    save()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
        .onAppear(perform: load)
        .confirmationDialog(
            "Let the AI write freely?",
            isPresented: $isConfirmingLoosenedAccess,
            titleVisibility: .visible
        ) {
            Button("Switch to AI Writes Freely") {
                save()
            }
            // The popover-style presentation this dialog gets inside a
            // sheet on iOS does not add the automatic Cancel button, so
            // declare one; presentations that do auto-add it dedupe.
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI changes to this collection will apply immediately instead of asking you first. Each write still shows in chat with undo.")
        }
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard case .edit(let collection) = mode else { return }
        title = collection.title
        details = collection.details ?? ""
        tagsText = collection.tags.joined(separator: ", ")
        accessLevel = collection.accessLevel
        scope = collection.scope
        isPinned = collection.isPinned
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = Self.parseTags(tagsText)

        do {
            switch mode {
            case .create:
                try repository.createCollection(
                    title: trimmedTitle,
                    details: trimmedDetails.isEmpty ? nil : trimmedDetails,
                    tags: tags,
                    accessLevel: accessLevel,
                    scope: scope,
                    isPinned: isPinned,
                    createdBy: .user
                )
            case .edit(let collection):
                let newDetails = trimmedDetails.isEmpty ? nil : trimmedDetails
                // One save for the whole edit: a failure leaves the
                // collection exactly as it was, never half-updated.
                try repository.performBatch {
                    // Only record an "Edited collection" event when one of
                    // these fields actually changed — otherwise a pure
                    // access-level or scope switch logs two activity rows
                    // for one action.
                    if collection.title != trimmedTitle || collection.details != newDetails
                        || collection.tags != tags || collection.isPinned != isPinned {
                        try repository.updateCollection(
                            collection,
                            title: trimmedTitle,
                            details: newDetails,
                            tags: tags,
                            isPinned: isPinned,
                            actor: .user
                        )
                    }
                    if collection.accessLevel != accessLevel {
                        try repository.setAccessLevel(accessLevel, for: collection)
                    }
                    if collection.scope != scope {
                        try repository.setScope(scope, for: collection, actor: .user)
                    }
                }
            }
        } catch {
            // Keep the sheet (and the user's input) open on failure.
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        dismiss()
    }

    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
