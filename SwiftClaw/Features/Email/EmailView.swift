import SwiftUI
import SwiftData
import QuickLook
#if os(macOS)
import WebKit
#endif

struct EmailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @Query(sort: \EmailThread.lastDate, order: .reverse)
    private var threads: [EmailThread]

    @State private var selectedThreadID: UUID?
    @State private var selectedMailbox: EmailMailbox = .inbox
    @State private var composingReplyFor: Email?
    var pendingEmailID: UUID?

    private var isConfigured: Bool {
        EmailAccountStore.shared.hasConfiguredAccount
    }

    /// Inbox surfaces any thread that still has at least one visible
    /// (non-archived + non-deleted) message. (We fetch *all* threads
    /// unfiltered via `@Query` so Archive/Trash mailboxes can read off the
    /// same list — the per-mailbox split happens here in code.)
    private var inboxThreads: [EmailThread] {
        threads.filter { thread in
            thread.messages.contains { message in
                !message.isArchived && !message.isDeleted
            }
        }
    }

    private var archiveThreads: [EmailThread] {
        threads.filter { $0.containsArchived }
    }

    private var trashThreads: [EmailThread] {
        threads.filter { $0.containsTrashed }
    }

    private var filteredThreads: [EmailThread] {
        switch selectedMailbox {
        case .inbox:
            inboxThreads
        case .flagged:
            inboxThreads.filter { $0.isFlagged }
        case .archive:
            archiveThreads
        case .trash:
            trashThreads
        }
    }

    private var selectedThread: EmailThread? {
        filteredThreads.first { $0.id == selectedThreadID } ?? filteredThreads.first
    }

    /// Archive / Trash are hidden when empty so the sidebar never advertises
    /// dead mailboxes; Inbox + Flagged are always present.
    private var visibleMailboxes: [EmailMailbox] {
        var visible: [EmailMailbox] = [.inbox, .flagged]
        if !archiveThreads.isEmpty { visible.append(.archive) }
        if !trashThreads.isEmpty { visible.append(.trash) }
        return visible
    }

    /// True when the account has *any* mail anywhere (Inbox / Archive /
    /// Trash). Used as the gate for the full-screen empty state — the
    /// per-mailbox "no messages" placeholder lives inside `threadLayout`
    /// so the sidebar stays reachable when the selected mailbox is empty
    /// (e.g. Flagged with nothing flagged). Otherwise switching to an
    /// empty mailbox replaces the whole pane with a centered placeholder
    /// and strands the user with no way back to Inbox without leaving
    /// the Email tab.
    private var hasAnyMail: Bool {
        !inboxThreads.isEmpty || !archiveThreads.isEmpty || !trashThreads.isEmpty
    }

    var body: some View {
        Group {
            if !isConfigured {
                unconfiguredState
            } else if !hasAnyMail {
                emptyState
            } else {
                threadLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await refreshNow() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.clockwise")
                }
                .help("Sync mail now")
                .disabled(MailSyncMonitor.shared.isSyncing)

                Button {
                    Task { await reviewNow() }
                } label: {
                    if MailSyncMonitor.shared.isReviewing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Review Now", systemImage: "sparkles")
                    }
                }
                .help("Run an inbox review pass now")
                .disabled(MailSyncMonitor.shared.isReviewing)

                // Open Settings → Email directly rather than via a sheet
                // containing only a "Open Settings" link (which forces a
                // second click to reach the real settings pane).
                SettingsLink {
                    Label("Email Settings", systemImage: "gear")
                }
                .help("Open Email settings")
            }
        }
        .sheet(item: $composingReplyFor) { email in
            if let account = EmailAccountStore.shared.account(for: email.accountID) {
                EmailReplyComposerView(email: email, account: account)
            } else {
                Text("The account for this email has been removed.")
                    .padding()
            }
        }
        .onChange(of: filteredThreads.first?.id) { _, _ in
            if selectedThreadID == nil {
                selectedThreadID = filteredThreads.first?.id
            }
        }
        .onAppear {
            if let emailID = pendingEmailID,
               let thread = threads.first(where: { $0.messages.contains { $0.id == emailID } }) {
                selectedThreadID = thread.id
            }
        }
        .onChange(of: pendingEmailID) { _, emailID in
            guard let emailID,
                  let thread = threads.first(where: { $0.messages.contains { $0.id == emailID } }) else { return }
            selectedThreadID = thread.id
        }
    }

    private var threadLayout: some View {
        HStack(spacing: 0) {
            EmailMailboxSidebar(
                selectedMailbox: $selectedMailbox,
                syncStatusLabel: MailSyncMonitor.shared.statusLabel,
                isSyncing: MailSyncMonitor.shared.isSyncing,
                visibleMailboxes: visibleMailboxes,
                lastSyncDate: MailSyncMonitor.shared.lastSyncDate,
                lastNewMessageCount: MailSyncMonitor.shared.lastNewMessageCount,
                lastRemovedMessageCount: MailSyncMonitor.shared.lastRemovedMessageCount
            )
            .frame(width: 180)

            Divider()

            EmailThreadListView(
                threads: filteredThreads,
                selectedThreadID: Binding(
                    get: { selectedThread?.id },
                    set: { selectedThreadID = $0 }
                )
            )
            .frame(width: 280)

            Divider()

            if let selectedThread {
                EmailThreadDetailView(
                    thread: selectedThread,
                    onReply: { email in composingReplyFor = email }
                )
            } else {
                FeaturePlaceholderView(
                    systemImage: "envelope.open",
                    title: "No thread selected",
                    message: "Pick one from the list."
                )
            }
        }
    }

    private var unconfiguredState: some View {
        FeaturePlaceholderView(
            systemImage: "envelope",
            title: "Email isn't configured",
            message: "Add IMAP and SMTP credentials in Settings → Email."
        )
        .overlay(alignment: .bottom) {
            SettingsLink {
                Text("Open Email Settings")
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 24)
        }
    }

    private var emptyState: some View {
        FeaturePlaceholderView(
            systemImage: "envelope",
            title: "No messages",
            message: MailSyncMonitor.shared.isSyncing ? "Syncing mail…" : "Sync to fetch messages."
        )
    }

    private func refreshNow() async {
        guard !ProcessInfo.processInfo.isRunningInPreview else { return }
        // Route through `EmailWorkflowManager` (not a one-off
        // `MailSyncWorker`) so a manual sync also kicks an immediate review
        // pass — otherwise the user has to wait up to
        // `emailReviewIntervalSeconds` for triage after a sync.
        await EmailWorkflowManager.shared.refreshNow()
    }

    private func reviewNow() async {
        guard !ProcessInfo.processInfo.isRunningInPreview else { return }
        await EmailWorkflowManager.shared.reviewNow()
    }
}

// MARK: - Mailboxes

enum EmailMailbox: String, CaseIterable, Identifiable {
    case inbox = "Inbox"
    case flagged = "Flagged"
    case archive = "Archive"
    case trash = "Trash"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .flagged: "flag"
        case .archive: "archivebox"
        case .trash: "trash"
        }
    }
}

private struct EmailMailboxSidebar: View {
    @Binding var selectedMailbox: EmailMailbox
    let syncStatusLabel: String?
    let isSyncing: Bool
    let visibleMailboxes: [EmailMailbox]

    /// Round-trips from the monitor so the footer can render "last synced
    /// 3m ago" alongside (or instead of) the transient status label. Passed
    /// in rather than read directly so SwiftUI's observation tracks the
    /// `@Observable MailSyncMonitor.shared` correctly across re-renders.
    let lastSyncDate: Date?
    let lastNewMessageCount: Int
    let lastRemovedMessageCount: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mailboxes")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(visibleMailboxes) { mailbox in
                        EmailMailboxRow(
                            mailbox: mailbox,
                            isSelected: selectedMailbox == mailbox,
                            select: { selectedMailbox = mailbox }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            footer
        }
        .background(.background.secondary)
    }

    @ViewBuilder
    private var footer: some View {
        if let syncStatusLabel, !syncStatusLabel.isEmpty {
            Divider()
            HStack(spacing: 6) {
                if isSyncing {
                    ProgressView().controlSize(.mini)
                }
                Text(syncStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let lastSyncDate {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
                Text("Synced \(lastSyncDate.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EmailMailboxRow: View {
    let mailbox: EmailMailbox
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: mailbox.systemImage)
                    .frame(width: 18)
                Text(mailbox.rawValue)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.18))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct EmailThreadListView: View {
    let threads: [EmailThread]
    @Binding var selectedThreadID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Threads")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if threads.isEmpty {
                // Per-mailbox empty placeholder — keeps the sidebar live so
                // the user can switch back to Inbox without leaving the tab.
                FeaturePlaceholderView(
                    systemImage: "tray",
                    title: "Nothing here",
                    message: "This mailbox is empty."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(threads.enumerated()), id: \.element.id) { index, thread in
                            EmailThreadRow(
                                thread: thread,
                                isSelected: thread.id == selectedThreadID,
                                select: { selectedThreadID = thread.id }
                            )
                            if index < threads.count - 1 {
                                EmailItemSeparator()
                                    .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(.background.secondary)
    }
}

private struct EmailThreadRow: View {
    let thread: EmailThread
    let isSelected: Bool
    let select: () -> Void

    @State private var showingNotes = false

    private var hasNotes: Bool {
        thread.messages.contains { !$0.notes.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if thread.isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
                Text(thread.latestMessage?.fromAddress ?? "Unknown")
                    .font(.subheadline)
                    .fontWeight(thread.unreadCount > 0 ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                Text(EmailDisplayDateFormatter.label(for: thread.lastDate))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if hasNotes {
                    Button {
                        showingNotes.toggle()
                    } label: {
                        Image(systemName: "note.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Show notes")
                    .popover(isPresented: $showingNotes) {
                        EmailNotesPopover(emails: thread.sortedMessages)
                    }
                }
            }
            Text(thread.latestMessage?.subject ?? "(no subject)")
                .font(.callout)
                .fontWeight(thread.unreadCount > 0 ? .semibold : .regular)
                .lineLimit(1)
            Text(thread.latestMessage?.snippet ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if thread.unreadCount > 0 {
                Text("\(thread.unreadCount) unread")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground)
        }
        .onTapGesture(perform: select)
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if thread.unreadCount > 0 { return Color.accentColor.opacity(0.07) }
        return .clear
    }
}

private struct EmailNotesPopover: View {
    let emails: [Email]

    private var noteGroups: [EmailNoteGroup] {
        emails.compactMap { email in
            let notes = email.notes.sorted { $0.createdAt < $1.createdAt }
            return notes.isEmpty ? nil : EmailNoteGroup(email: email, notes: notes)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes")
                .font(.headline)
            ForEach(noteGroups) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.email.subject.isEmpty ? "(no subject)" : item.email.subject)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ForEach(item.notes) { note in
                        Text(note.content)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct EmailNoteGroup: Identifiable {
    let email: Email
    let notes: [EmailNote]

    var id: UUID { email.id }
}

private struct EmailThreadDetailView: View {
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

    /// Trash-mailbox "Delete Permanently": hard-deletes the local row (+ its
    /// notes + on-disk attachment bytes via `repository().deletePermanently`)
    /// AND expunges the server copy via `MailClient.deletePermanently`. Two
    /// actions because local + server are independent stores — the local row
    /// existing in Trash already implies a prior `delete` (move-to-Trash),
    /// so the server-side call here is the expunge on the Trash mailbox.
    private func permanentlyDelete(_ email: Email) {
        // Server-side expunge first (best-effort — losing local-only state
        // because the server call failed would be worse than leaving the
        // server copy to be re-synced). If the account has been removed the
        // server-side call is skipped; the local hard-delete still runs.
        let mailClient = EmailMailClientResolver.mailClient(for: email)
        let mailbox = email.mailbox
        let uid = email.uid
        if let mailClient {
            Task {
                do {
                    try await mailClient.deletePermanently(uid: uid, in: mailbox)
                } catch {
                    MailSyncMonitor.shared.setStatus(
                        "Couldn't expunge from the server: \(error.localizedDescription)",
                        syncing: false
                    )
                }
            }
        }
        repository().deletePermanently(messageID: email.id)
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

private struct EmailItemSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.16))
            .frame(height: 1)
            .padding(.horizontal, 8)
    }
}

private struct EmailMessageCard: View {
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

private struct EmailNoteEditor: View {
    let email: Email
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var noteText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Note")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Note for: \(email.subject)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $noteText)
                    .frame(minHeight: 160)
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
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

// MARK: - Reply composer

private struct EmailReplyComposerView: View {
    let email: Email
    let account: StoredEmailAccount
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var toAddresses: String = ""
    @State private var ccAddresses: String = ""
    @State private var subject: String = ""
    @State private var bodyText: String = ""
    @State private var isSending = false
    @State private var sendError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reply")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            Form {
                Section("Recipients") {
                    TextField("To", text: $toAddresses)
                    TextField("Cc", text: $ccAddresses)
                }
                Section("Subject") {
                    TextField("Subject", text: $subject)
                }
                Section("Body") {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 220)
                }
                if let sendError {
                    Section {
                        Text(sendError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Send") {
                    Task { await send() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending || toAddresses.isEmpty)
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 480)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        toAddresses = email.fromAddress
        ccAddresses = email.ccAddresses.joined(separator: ", ")
        subject = email.subject.lowercased().hasPrefix("re:")
            ? email.subject
            : "Re: \(email.subject)"
        bodyText = Self.replyQuote(for: email)
    }

    /// Builds the reply body: an empty compose area on top followed by a
    /// standard `--- ... wrote:` separator + the replied message's full plain
    /// text body line-prefixed with `> `. Quoting the full body (instead of
    /// the previous 140-char `snippet`) makes the reply actually usable —
    /// the recipient sees their original message with context preserved, and
    /// the sender can edit down inline.
    ///
    /// Truncated to a sane upper bound so a 200KB plaintext newsletter
    /// doesn't blow up the composer + the outgoing SMTP payload. 8000 chars
    /// ≈ 4-5 screens; anything longer gets a `[…]` marker.
    private static func replyQuote(for email: Email) -> String {
        let original = email.plainTextBody
        let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = 8000
        let quoted: String
        if trimmed.count <= cap {
            quoted = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
        } else {
            let prefix = String(trimmed.prefix(cap))
            let block = prefix.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            quoted = block + "\n> […]\n"
        }
        return "\n\n---\nOn \(email.date.formatted()), \(email.fromAddress) wrote:\n\(quoted)"
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        do {
            // Generate one Message-ID up front so the delivered message,
            // the Sent-folder APPEND, and the local seed row all share it.
            // `upsertSentMessage` dedups on this value, so a shared ID also
            // makes double-Send + a future Sent-folder sync idempotent.
            let domain = accountFromAddressDomain()
            let messageID = "<\(UUID().uuidString)@\(domain)>"
            let outgoing = OutgoingEmail(
                fromAddress: account.fromAddress,
                toAddresses: parseAddresses(toAddresses),
                ccAddresses: parseAddresses(ccAddresses),
                subject: subject,
                bodyText: bodyText,
                messageID: messageID,
                inReplyTo: email.messageID,
                references: email.allReferenceIDs
            )
            try await SwiftMailClient(account: account).send(outgoing)
            // Locally record the just-sent reply so it shows up in the
            // thread immediately. See `EmailRepository.upsertSentMessage`
            // for the synthetic-row lifecycle (uid is client-side + the
            // row gets promoted on the next Sent-folder sync).
            let sentMailbox = account.resolvedSentMailbox ?? "Sent"
            EmailRepository(modelContext: modelContext).upsertSentMessage(
                outgoing,
                account: account,
                sentMailbox: sentMailbox
            )
            dismiss()
        } catch {
            sendError = error.localizedDescription
        }
    }

    private func parseAddresses(_ raw: String) -> [String] {
        raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Extracts the domain for the Message-ID host (e.g. `me@example.com`
    /// → `example.com`). Falls back to `localhost` if parsing fails.
    private func accountFromAddressDomain() -> String {
        let address = account.fromAddress
        if let at = address.lastIndex(of: "@"),
           at < address.endIndex {
            let domain = address[address.index(after: at)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !domain.isEmpty {
                return String(domain)
            }
        }
        return "localhost"
    }
}

// MARK: - Attachment list + QuickLook viewer

private struct EmailAttachmentList: View {
    let attachments: [EmailAttachment]
    let emailID: UUID

    @State private var previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Attachments")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(attachments) { attachment in
                Button {
                    previewURL = resolveURL(for: attachment)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: AttachmentIconSystemName.value(for: attachment.mimeType))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.filename)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(AttachmentFormatter.sizeString(attachment.sizeBytes))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if attachment.filePath.isEmpty {
                            Text("unavailable")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(attachment.filePath.isEmpty)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                }
            }
        }
        .quickLookPreview($previewURL)
    }

    private func resolveURL(for attachment: EmailAttachment) -> URL? {
        guard !attachment.filePath.isEmpty else { return nil }
        return EmailAttachmentStore.shared.absoluteURL(
            forEmailID: emailID,
            filename: attachment.filename
        )
    }
}

private enum AttachmentIconSystemName {
    /// Picks a SF Symbol for an attachment based on its declared MIME type.
    /// Anything unrecognised falls back to the generic paperclip.
    static func value(for mimeType: String) -> String {
        let lower = mimeType.lowercased()
        if lower.hasPrefix("image/") { return "photo" }
        if lower.hasPrefix("video/") { return "film" }
        if lower.hasPrefix("audio/") { return "music.note" }
        if lower.contains("pdf") { return "doc.text.fill" }
        if lower.contains("zip") || lower.contains("compressed") { return "archivebox" }
        if lower.contains("spreadsheet") || lower.contains("excel") { return "tablecells" }
        if lower.contains("presentation") || lower.contains("powerpoint") { return "rectangle.on.rectangle" }
        if lower.contains("word") || lower.contains("document") { return "doc.text" }
        if lower.contains("json") || lower.contains("xml") || lower.contains("text") { return "doc.plaintext" }
        return "paperclip"
    }
}

private enum AttachmentFormatter {
    static func sizeString(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

#if os(macOS)
/// Renders HTML email bodies via WKWebView. Used when the server provides
/// an HTML part. Links open in the default browser.
private struct EmailHTMLBodyView: View {
    let html: String
    @State private var contentHeight: CGFloat = 160

    var body: some View {
        EmailHTMLView(html: html, contentHeight: $contentHeight)
            .frame(height: max(contentHeight, 120))
    }
}

private struct EmailHTMLView: NSViewRepresentable {
    let html: String
    @Binding var contentHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let webView = EmailScrollPassthroughWebView()
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        disableScrolling(in: webView)
        loadHTML(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        disableScrolling(in: webView)
        context.coordinator.contentHeight = $contentHeight
        if context.coordinator.currentHTML != html {
            loadHTML(in: webView, coordinator: context.coordinator)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentHeight: $contentHeight)
    }

    private func loadHTML(in webView: WKWebView, coordinator: Coordinator) {
        coordinator.currentHTML = html
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bg = isDark ? "#1e1e1e" : "#ffffff"
        let fg = isDark ? "#e0e0e0" : "#1a1a1a"
        let wrapped = """
        <html><head><meta charset="utf-8">
        <style>
            html, body { overflow: hidden !important; height: auto !important; }
            body { background: \(bg); color: \(fg); font-family: -apple-system, sans-serif; \
            font-size: 14px; line-height: 1.5; margin: 0; padding: 8px; word-wrap: break-word; }
            * { max-width: 100% !important; max-height: none !important; overflow: visible !important; }
            ::-webkit-scrollbar { width: 0 !important; height: 0 !important; display: none !important; }
            a { color: -webkit-link; }
            img { max-width: 100%; height: auto; }
            table { max-width: 100%; }
            pre { white-space: pre-wrap; word-wrap: break-word; }
        </style>
        </head><body>\(html)</body></html>
        """
        webView.loadHTMLString(wrapped, baseURL: nil)
    }

    private func disableScrolling(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.verticalScrollElasticity = .none
            scrollView.horizontalScrollElasticity = .none
        }
        for subview in view.subviews {
            disableScrolling(in: subview)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var contentHeight: Binding<CGFloat>
        var currentHTML: String?

        init(contentHeight: Binding<CGFloat>) {
            self.contentHeight = contentHeight
        }

        func webView(_ webView: WKWebView,
                      decidePolicyFor navigationAction: WKNavigationAction,
                      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateContentHeight(for: webView)
        }

        private func updateContentHeight(for webView: WKWebView) {
            webView.evaluateJavaScript(
                """
                (() => {
                    const nodes = [document.documentElement, document.body, ...document.body.querySelectorAll('*')];
                    return Math.ceil(nodes.reduce((height, node) => {
                        const rect = node.getBoundingClientRect();
                        return Math.max(height, rect.bottom, node.scrollHeight || 0, node.offsetHeight || 0);
                    }, 0));
                })()
                """
            ) { [weak self] value, _ in
                guard let self else { return }
                let measured = (value as? NSNumber)?.doubleValue ?? 0
                Task { @MainActor in
                    self.contentHeight.wrappedValue = max(CGFloat(measured), 120)
                }
            }
        }
    }
}

private final class EmailScrollPassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if let parentScrollView {
            parentScrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private var parentScrollView: NSScrollView? {
        var current = superview
        while let view = current {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            current = view.superview
        }
        return nil
    }
}
#endif

#Preview {
    EmailView()
        .modelContainer(for: [
            Email.self,
            EmailThread.self,
            EmailNote.self,
            EmailAttachment.self
        ])
}
