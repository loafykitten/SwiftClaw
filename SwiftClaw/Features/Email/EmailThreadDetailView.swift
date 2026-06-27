import SwiftUI
import SwiftData

/// Thread (multi-message) detail view + per-message card + note editor.
/// Extracted from `EmailView.swift` along the detail-pane concern boundary.
struct EmailThreadDetailView: View {
    let thread: EmailThread
    let onReply: (Email) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var pendingDestructive: Email?

    /// Pending archive — kept separate from `pendingDestructive` (delete)
    /// so each action surfaces its own confirmation text and the destructive
    /// role styling is preserved. Both archive and delete are now two-click
    /// per the plan's "mirror ChatHistoryActionButton" guidance.
    @State private var pendingArchive: Email?

    /// Pending permanent-delete (Trash-only). Hard-deletes the row +
    /// associated notes/attachment bytes + server-side `deletePermanently`
    /// expunge. Two-click (confirmation) like the recoverable delete path;
    /// message makes the irrecoverable nature explicit.
    @State private var pendingPermanentDelete: Email?

    /// Note composer target. `EmailNoteEditor` saves through
    /// `EmailRepository.addNote(...)` (author `.user`).
    @State private var composingNoteFor: Email?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thread.latestMessage?.subject ?? "(no subject)")
                        .font(.headline)
                        .lineLimit(2)
                    Text(thread.participantSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 12) {
                    let messages = thread.sortedMessages
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, email in
                        EmailMessageCard(
                            email: email,
                            onMarkRead: { markAsReadIfNeeded(email) },
                            onReply: { onReply(email) },
                            onArchive: { pendingArchive = email },
                            onDelete: { pendingDestructive = email },
                            onPermanentDelete: { pendingPermanentDelete = email },
                            onToggleFlag: { toggleFlag(email) },
                            onAddNote: { composingNoteFor = email }
                        )
                        if index < messages.count - 1 {
                            EmailItemSeparator()
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Delete this email?",
            isPresented: Binding(
                get: { pendingDestructive != nil },
                set: { if !$0 { pendingDestructive = nil } }
            ),
            presenting: pendingDestructive
        ) { email in
            Button("Delete", role: .destructive) {
                delete(email)
                pendingDestructive = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDestructive = nil
            }
        } message: { _ in
            // "Delete" moves to the Trash mailbox (recoverable) rather than
            // expunging from the server. The irreversible expunge path is
            // reserved for the Trash mailbox's "Delete Permanently" action.
            Text("The email will be moved to the Trash mailbox on the server.")
        }
        .confirmationDialog(
            "Archive this email?",
            isPresented: Binding(
                get: { pendingArchive != nil },
                set: { if !$0 { pendingArchive = nil } }
            ),
            presenting: pendingArchive
        ) { email in
            Button("Archive") {
                archive(email)
                pendingArchive = nil
            }
            Button("Cancel", role: .cancel) {
                pendingArchive = nil
            }
        } message: { _ in
            Text("The email will be moved to the Archive mailbox on the server.")
        }
        .sheet(item: $composingNoteFor) { email in
            EmailNoteEditor(email: email)
        }
        .confirmationDialog(
            "Delete this email permanently?",
            isPresented: Binding(
                get: { pendingPermanentDelete != nil },
                set: { if !$0 { pendingPermanentDelete = nil } }
            ),
            presenting: pendingPermanentDelete
        ) { email in
            Button("Delete Permanently", role: .destructive) {
                permanentlyDelete(email)
                pendingPermanentDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingPermanentDelete = nil
            }
        } message: { _ in
            // Make the irrecoverable nature explicit — both the local row +
            // its notes (and any attachment bytes on disk) are removed, and
            // the server copy is expunged from the Trash folder. There's no
            // undo.
            Text("The email will be permanently deleted from the server and from SwiftClaw. This action cannot be undone.")
        }
    }

    private func repository() -> EmailRepository {
        EmailRepository(modelContext: modelContext)
    }

    /// Marks a single message as read on the server when its card appears.
    /// Per-message rather than per-thread so only what the user actually sees
    /// gets the `\Seen` flag — older messages in a thread stay unread until
    /// scrolled to.
    private func markAsReadIfNeeded(_ email: Email) {
        guard !email.isRead else { return }
        Task {
            await EmailServerAction.setFlags(
                email: email,
                repository: repository(),
                mailClient: EmailMailClientResolver.mailClient(for: email),
                isRead: true,
                isFlagged: nil
            )
        }
    }

    private func archive(_ email: Email) {
        Task {
            await EmailServerAction.archive(
                email: email,
                repository: repository(),
                mailClient: EmailMailClientResolver.mailClient(for: email)
            )
        }
    }

    private func delete(_ email: Email) {
        Task {
            await EmailServerAction.delete(
                email: email,
                repository: repository(),
                mailClient: EmailMailClientResolver.mailClient(for: email)
            )
        }
    }

    /// Trash-mailbox "Delete Permanently". Routes through `EmailServerAction`
    /// like every sibling action (archive/delete/toggleFlag) so the server
    /// expunge + local hard-delete + error surface stay coordinated in one
    /// place rather than diverging in the view.
    private func permanentlyDelete(_ email: Email) {
        Task {
            await EmailServerAction.deletePermanently(
                email: email,
                repository: repository(),
                mailClient: EmailMailClientResolver.mailClient(for: email)
            )
        }
    }

    private func toggleFlag(_ email: Email) {
        Task {
            await EmailServerAction.toggleFlag(
                email: email,
                repository: repository(),
                mailClient: EmailMailClientResolver.mailClient(for: email)
            )
        }
    }
}

struct EmailItemSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.16))
            .frame(height: 1)
            .padding(.horizontal, 8)
    }
}

struct EmailMessageCard: View {
    let email: Email
    let onMarkRead: () -> Void
    let onReply: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onPermanentDelete: () -> Void
    let onToggleFlag: () -> Void
    let onAddNote: () -> Void
    @State private var showingNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(email.fromAddress)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(EmailDisplayDateFormatter.label(for: email.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if !email.notes.isEmpty {
                    Button {
                        showingNotes.toggle()
                    } label: {
                        Image(systemName: "note.text")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Show notes")
                    .popover(isPresented: $showingNotes) {
                        EmailNotesPopover(emails: [email])
                    }
                }
                Button {
                    onToggleFlag()
                } label: {
                    Image(systemName: email.isFlagged ? "flag.fill" : "flag")
                        .foregroundStyle(email.isFlagged ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(email.isFlagged ? "Unflag" : "Flag")
            }

            if let html = email.bodyHTML,
               !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmailHTMLBodyView(html: html)
            } else if !email.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(email.bodyText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if !email.attachments.isEmpty {
                EmailAttachmentList(attachments: email.attachments, emailID: email.id)
            }

            HStack(spacing: 8) {
                Button {
                    onReply()
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
                Button {
                    onAddNote()
                } label: {
                    Label("Add Note", systemImage: "note.text")
                }
                Button {
                    onArchive()
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                // Hide the recoverable Delete on rows already in the Trash
                // mailbox — `delete` there is a no-op (re-sets `isDeleted`
                // which is already true). The permanent-delete affordance
                // below is the meaningful action for trashed rows.
                if !email.isDeleted {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                // The permanent-delete affordance only renders for rows that
                // are already in the Trash mailbox (`isDeleted == true`) —
                // otherwise the recoverable Delete above is the right action.
                if email.isDeleted {
                    Button(role: .destructive) {
                        onPermanentDelete()
                    } label: {
                        Label("Delete Permanently", systemImage: "xmark.bin.fill")
                    }
                }
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(email.isRead ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.08))
        }
        .onAppear { onMarkRead() }
    }
}

// MARK: - Note editor

struct EmailNoteEditor: View {
    let email: Email
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var noteText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Add Note") { dismiss() }

            VStack(alignment: .leading, spacing: 8) {
                Text("Note for: \(email.subject)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $noteText)
                    .frame(minHeight: 160)
            }
            .padding(20)

            SheetFooter(
                confirmTitle: "Save",
                isDisabled: noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                save()
            }
        }
        .frame(minWidth: 440, minHeight: 360)
    }

    private func save() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        EmailRepository(modelContext: modelContext).addNote(
            emailID: email.id,
            author: .user,
            content: trimmed
        )
        dismiss()
    }
}
