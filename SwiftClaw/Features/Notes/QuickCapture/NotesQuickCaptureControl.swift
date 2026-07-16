import SwiftUI

/// Shared quick-capture field used by the Notes toolbar and Workspace sheet.
/// The field clears only after the repository, index, and capture counter all
/// update successfully; failures leave the user's text intact.
struct NotesQuickCaptureControl: View {
    let model: NotesFeatureModel
    var onCaptured: (String) -> Void = { _ in }

    @State private var text = ""
    @State private var destination: NotesQuickCaptureService.Destination = .dailyNote
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 8) {
            TextField("Quick capture", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .disabled(isSaving || model.repository == nil)
                .accessibilityIdentifier("notes.quickCapture.text")

            Menu {
                Button {
                    destination = .dailyNote
                } label: {
                    Label("Today's Daily Note", systemImage: destination == .dailyNote ? "checkmark" : "calendar")
                }
                Button {
                    destination = .standaloneNote
                } label: {
                    Label("Standalone Note", systemImage: destination == .standaloneNote ? "checkmark" : "note.text")
                }
            } label: {
                Image(systemName: destination == .dailyNote ? "calendar" : "note.text")
            }
            .help(destination == .dailyNote ? "Capture to today's daily note" : "Capture as a standalone note")
            .accessibilityLabel("Quick capture destination")
            .accessibilityValue(destination == .dailyNote ? "Today's Daily Note" : "Standalone Note")
            .accessibilityIdentifier("notes.quickCapture.destination")

            Button(action: submit) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.doc")
                }
            }
            .disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.repository == nil)
            .help("Save quick capture")
            .accessibilityLabel("Save quick capture")
            .accessibilityIdentifier("notes.quickCapture.save")
        }
        .alert(
            "Couldn't Save Quick Capture",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: {
                    if !$0 {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "The capture couldn't be saved.")
        }
    }

    private func submit() {
        guard !isSaving else { return }
        let capturedText = text
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let path = try await model.quickCapture(capturedText, destination: destination)
                text = ""
                onCaptured(path)
            } catch {
                errorMessage = NotesError.from(error).errorDescription
            }
        }
    }
}

struct NotesQuickCaptureSheet: View {
    let model: NotesFeatureModel
    var onCaptured: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.configurationState == .configured {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Send a thought to today's daily note or save it as its own Markdown file.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NotesQuickCaptureControl(model: model) { path in
                            onCaptured(path)
                            dismiss()
                        }
                    }
                    .padding()
                    .frame(maxWidth: 520, alignment: .leading)
                } else {
                    ContentUnavailableView(
                        "Set Up Notes First",
                        systemImage: "note.text",
                        description: Text("Open Notes and choose a vault before using quick capture.")
                    )
                }
            }
            .navigationTitle("Quick Capture")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 180)
    }
}
