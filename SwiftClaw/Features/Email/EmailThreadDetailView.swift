import SwiftUI
import SwiftData

/// Thread (multi-message) detail view + per-message card + note editor.
/// Extracted from `EmailView.swift` along the detail-pane concern boundary.
struct EmailThreadDetailView: View {
    let thread: EmailThread
    var accountLabel: String?
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
                    if let accountLabel {
                        EmailAccountBadge(label: accountLabel)
                            .padding(.top, 2)
                    }
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
        .confirmingAction(
            item: $pendingDestructive,
            copy: ConfirmationDialogCopy(
                title: "Delete this email?",
                actionTitle: "Delete",
                message: "The email will be moved to the Trash mailbox on the server."
            ),
            action: delete
        )
        .confirmingAction(
            item: $pendingArchive,
            copy: ConfirmationDialogCopy(
                title: "Archive this email?",
                actionTitle: "Archive",
                message: "The email will be moved to the Archive mailbox on the server.",
                role: nil
            ),
            action: archive
        )
        .sheet(item: $composingNoteFor) { email in
            EmailNoteEditor(email: email)
        }
        .confirmingAction(
            item: $pendingPermanentDelete,
            copy: ConfirmationDialogCopy(
                title: "Delete this email permanently?",
                actionTitle: "Delete Permanently",
                message: "The email will be permanently deleted from the server and from SwiftClaw. This action cannot be undone."
            ),
            action: permanentlyDelete
        )
    }

    private func repository() -> EmailRepository {
        EmailRepository(modelContext: modelContext)
    }

    /// Marks a single message as read on the server when its card appears.
    /// Per-message rather than per-thread so only what the user actually sees
    /// gets the `\Seen` flag — older messages in a thread stay unread until
    /// scrolled to.
    private func markAsReadIfNeeded(_ email: Email) {
        // Reading the message in-app retires its delivered notification and
        // the account's digest (its "N new messages" count is stale now).
        AppNotificationService.shared.removeDeliveredEmailNotification(
            emailID: email.id,
            accountID: email.accountID
        )
        guard !email.isRead else { return }
        runServerAction(.markRead, email: email) {
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
        runServerAction(.archive, email: email) {
            await EmailServerAction.archive(
                email: email,
                repository: repository(),
                mailClient: EmailMailClientResolver.mailClient(for: email)
            )
        }
    }

    private func delete(_ email: Email) {
        runServerAction(.delete, email: email) {
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
        runServerAction(.permanentDelete, email: email) {
            await EmailServerAction.deletePermanently(
                email: email,
                repository: repository(),
                mailClient: EmailMailClientResolver.mailClient(for: email)
            )
        }
    }

    private func toggleFlag(_ email: Email) {
        runServerAction(.toggleFlag, email: email) {
            await EmailServerAction.toggleFlag(
                email: email,
                repository: repository(),
                mailClient: EmailMailClientResolver.mailClient(for: email)
            )
        }
    }

    private func runServerAction(
        _ kind: EmailServerActionKind,
        email: Email,
        operation: @escaping @MainActor () async -> Void
    ) {
        EmailServerActionCoordinator.shared.run(
            kind,
            emailID: email.id,
            operation: operation
        )
    }
}

@MainActor
private final class EmailServerActionCoordinator {
    static let shared = EmailServerActionCoordinator()

    private var tasks: [EmailServerActionTaskKey: Task<Void, Never>] = [:]

    private init() {}

    func run(
        _ kind: EmailServerActionKind,
        emailID: UUID,
        operation: @escaping @MainActor () async -> Void
    ) {
        let key = EmailServerActionTaskKey(emailID: emailID, kind: kind)
        guard tasks[key] == nil else { return }

        tasks[key] = Task { @MainActor [weak self] in
            await operation()
            self?.tasks[key] = nil
        }
    }
}

private struct EmailServerActionTaskKey: Hashable {
    let emailID: UUID
    let kind: EmailServerActionKind
}

private enum EmailServerActionKind: Hashable {
    case markRead
    case archive
    case delete
    case permanentDelete
    case toggleFlag
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
                    Text(email.displayFromAddress)
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
                    .emailNotesPresentation(
                        isPresented: $showingNotes,
                        emails: [email]
                    )
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

            // Full labels when the card is wide enough, icon-only when it
            // isn't — a fixed row hyphen-wraps button titles ("Ar-chive") at
            // compact widths.
            ViewThatFits(in: .horizontal) {
                actionRow(iconOnly: false)
                actionRow(iconOnly: true)
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

    @ViewBuilder
    private func actionRow(iconOnly: Bool) -> some View {
        let row = HStack(spacing: 8) {
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
        .lineLimit(1)

        if iconOnly {
            row.labelStyle(.iconOnly)
        } else {
            row.labelStyle(.titleAndIcon)
        }
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
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
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
