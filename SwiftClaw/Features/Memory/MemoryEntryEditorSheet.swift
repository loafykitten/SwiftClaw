import SwiftUI

/// Create or edit one memory entry. User edits apply in place
/// (`MemoryRepository.editEntry`) — supersession is the *AI's* update path
/// for established facts; the user owns the store outright.
struct MemoryEntryEditorSheet: View {
    enum Mode {
        case create(defaultCollection: MemoryCollection?)
        case edit(MemoryEntry)
    }

    let mode: Mode
    let repository: MemoryRepository
    let collections: [MemoryCollection]

    @Environment(\.dismiss) private var dismiss
    @State private var bodyText = ""
    @State private var tagsText = ""
    @State private var collectionID: UUID?
    @State private var hasLoaded = false
    @State private var saveError: String?

    private var sheetTitle: String {
        switch mode {
        case .create: "New Memory"
        case .edit: "Edit Memory"
        }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private var isValid: Bool {
        !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isCreating || collectionID != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: sheetTitle) {
                dismiss()
            }

            Form {
                Section {
                    TextField(
                        "Memory",
                        text: $bodyText,
                        prompt: Text("One short fact worth remembering"),
                        axis: .vertical
                    )
                    .lineLimit(2...6)
                    TextField("Tags", text: $tagsText, prompt: Text("Comma-separated"))
                }

                if isCreating {
                    Section {
                        Picker("Collection", selection: $collectionID) {
                            ForEach(collections) { collection in
                                Text(collection.title).tag(Optional(collection.id))
                            }
                        }
                    }
                }

                if let saveError {
                    MemorySaveErrorSection(message: saveError)
                }
            }
            .formStyle(.grouped)

            SheetFooter(confirmTitle: "Save", isDisabled: !isValid) {
                save()
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
        .onAppear(perform: load)
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch mode {
        case .create(let defaultCollection):
            collectionID = (defaultCollection ?? collections.first)?.id
        case .edit(let entry):
            bodyText = entry.body
            tagsText = entry.tags.joined(separator: ", ")
            collectionID = entry.collection?.id
        }
    }

    private func save() {
        let trimmedBody = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = MemoryCollectionEditorSheet.parseTags(tagsText)

        do {
            switch mode {
            case .create:
                guard let collectionID,
                      let collection = collections.first(where: { $0.id == collectionID }) else { return }
                try repository.addEntry(body: trimmedBody, tags: tags, to: collection, createdBy: .user)
            case .edit(let entry):
                try repository.editEntry(entry, body: trimmedBody, tags: tags, actor: .user)
            }
        } catch {
            // Keep the sheet (and the typed text) open on failure.
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        dismiss()
    }
}

/// Inline save-failure notice shared by the Memory editor sheets, which stay
/// open (keeping the user's input) when a save is rolled back.
struct MemorySaveErrorSection: View {
    let message: String

    var body: some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}
