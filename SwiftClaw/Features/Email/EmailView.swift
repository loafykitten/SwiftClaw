import SwiftUI
import SwiftData

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

    var body: some View {
        // Each partition filters all @Query threads and faults in
        // `thread.messages`, so compute them ONCE per render and derive
        // everything (filtered list, selection, visible mailboxes, the
        // empty-state gate) from these locals — reading the partitions
        // repeatedly used to re-run that work many times per `body` pass.
        let inbox = inboxThreads
        let archive = archiveThreads
        let trash = trashThreads

        let filtered: [EmailThread]
        switch selectedMailbox {
        case .inbox:
            filtered = inbox
        case .flagged:
            filtered = inbox.filter { $0.isFlagged }
        case .archive:
            filtered = archive
        case .trash:
            filtered = trash
        }
        let selected = filtered.first { $0.id == selectedThreadID } ?? filtered.first

        // Archive / Trash are hidden when empty so the sidebar never
        // advertises dead mailboxes; Inbox + Flagged are always present.
        var visibleMailboxes: [EmailMailbox] = [.inbox, .flagged]
        if !archive.isEmpty { visibleMailboxes.append(.archive) }
        if !trash.isEmpty { visibleMailboxes.append(.trash) }

        // True when the account has *any* mail anywhere (Inbox / Archive /
        // Trash). Gates the full-screen empty state — the per-mailbox "no
        // messages" placeholder lives inside `threadLayout` so the sidebar
        // stays reachable when the selected mailbox is empty (e.g. Flagged
        // with nothing flagged). Otherwise switching to an empty mailbox
        // replaces the whole pane with a centered placeholder and strands
        // the user with no way back to Inbox without leaving the Email tab.
        let hasAnyMail = !inbox.isEmpty || !archive.isEmpty || !trash.isEmpty

        return Group {
            if !isConfigured {
                unconfiguredState
            } else if !hasAnyMail {
                emptyState
            } else {
                threadLayout(
                    filtered: filtered,
                    selected: selected,
                    visibleMailboxes: visibleMailboxes
                )
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
        .onChange(of: filtered.first?.id) { _, _ in
            if selectedThreadID == nil {
                selectedThreadID = filtered.first?.id
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

    private func threadLayout(
        filtered: [EmailThread],
        selected: EmailThread?,
        visibleMailboxes: [EmailMailbox]
    ) -> some View {
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
                threads: filtered,
                selectedThreadID: Binding(
                    get: { selected?.id },
                    set: { selectedThreadID = $0 }
                )
            )
            .frame(width: 280)

            Divider()

            if let selected {
                EmailThreadDetailView(
                    thread: selected,
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
        // Bind these once per row — `latestMessage` sorts the thread's
        // messages and `unreadCount` scans them, and both were read several
        // times across this body (header, subject, unread badge, background).
        let latest = thread.latestMessage
        let unread = thread.unreadCount
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if thread.isFlagged {
                    Image(systemName: "flag.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                }
                Text(latest?.fromAddress ?? "Unknown")
                    .font(.subheadline)
                    .fontWeight(unread > 0 ? .semibold : .regular)
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
            Text(latest?.subject ?? "(no subject)")
                .font(.callout)
                .fontWeight(unread > 0 ? .semibold : .regular)
                .lineLimit(1)
            Text(latest?.snippet ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if unread > 0 {
                Text("\(unread) unread")
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
                .fill(rowBackground(unread: unread))
        }
        .onTapGesture(perform: select)
    }

    private func rowBackground(unread: Int) -> Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if unread > 0 { return Color.accentColor.opacity(0.07) }
        return .clear
    }
}

/// Popover listing per-message notes. `internal` (not `private`) because
/// `EmailMessageCard` in `EmailThreadDetailView.swift` also uses it.
struct EmailNotesPopover: View {
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

#Preview {
    EmailView()
        .modelContainer(for: [
            Email.self,
            EmailThread.self,
            EmailNote.self,
            EmailAttachment.self
        ])
}
