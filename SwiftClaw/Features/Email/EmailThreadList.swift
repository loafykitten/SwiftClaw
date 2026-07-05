import SwiftUI

/// The Email tab's thread-list layer, shared by `EmailView`'s regular
/// (sidebar) and compact (navigation-stack) layouts. Split out of
/// `EmailView.swift` to keep that file to the tab's own structure.
struct EmailThreadListView: View {
    let threads: [EmailThread]
    let mailbox: EmailMailbox
    let quickAction: ReviewActionToken
    @Binding var selectedThreadID: UUID?
    @Binding var searchText: String
    let isSearching: Bool
    let accountLabeler: EmailAccountLabeler
    let canLoadOlder: Bool
    let onLoadOlder: () -> Void
    let onQuickAction: (ReviewActionToken, EmailThread, EmailMailbox) -> Void

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
                EmptyMailboxView(
                    isSearching: isSearching,
                    mailboxImage: "tray",
                    canLoadOlder: canLoadOlder,
                    onLoadOlder: onLoadOlder
                )
            } else {
                #if os(macOS)
                List(selection: $selectedThreadID) {
                    ForEach(threads) { thread in
                        quickActionRow(for: thread) {
                            EmailThreadRow(
                                thread: thread,
                                isSelected: thread.id == selectedThreadID,
                                accountLabel: accountLabeler.label(for: thread)
                            )
                        }
                        .tag(thread.id)
                        .sidebarRowState(isEmphasized: thread.unreadCount > 0)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    }
                    if canLoadOlder {
                        LoadOlderMessagesButton(action: onLoadOlder)
                    }
                }
                .listStyle(.sidebar)
                #else
                List {
                    ForEach(threads) { thread in
                        quickActionRow(for: thread) {
                            Button {
                                selectedThreadID = thread.id
                            } label: {
                                EmailThreadRow(
                                    thread: thread,
                                    isSelected: thread.id == selectedThreadID,
                                    accountLabel: accountLabeler.label(for: thread)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .sidebarRowState(isEmphasized: thread.unreadCount > 0)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    }
                    if canLoadOlder {
                        LoadOlderMessagesButton(action: onLoadOlder)
                    }
                }
                .listStyle(.sidebar)
                #endif
            }
        }
        .searchable(text: $searchText, prompt: Text("Search \(mailbox.title)"))
    }

    private func quickActionRow<Content: View>(
        for thread: EmailThread,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        EmailQuickActionSwipe(
            action: quickAction,
            onPerform: { action in onQuickAction(action, thread, mailbox) },
            content: content
        )
        .accessibilityAction(named: Text(quickAction.displayName)) {
            onQuickAction(quickAction, thread, mailbox)
        }
    }
}

/// Empty state for a thread list: the system search placeholder while a
/// query is active, otherwise the app's per-mailbox placeholder. A full
/// fetch window can make a mailbox *look* empty when all its mail is older
/// than the window, so the load-older affordance stays reachable here too.
private struct EmptyMailboxView: View {
    let isSearching: Bool
    let mailboxImage: String
    let canLoadOlder: Bool
    let onLoadOlder: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if isSearching {
                ContentUnavailableView.search
            } else {
                FeaturePlaceholderView(
                    systemImage: mailboxImage,
                    title: "Nothing here",
                    message: "This mailbox is empty."
                )
            }
            if canLoadOlder {
                LoadOlderMessagesButton(action: onLoadOlder)
                    .padding(.bottom, 16)
            }
        }
    }
}

struct EmailThreadNavigationList: View {
    let mailbox: EmailMailbox
    let threads: [EmailThread]
    let quickAction: ReviewActionToken
    @Binding var searchText: String
    let isSearching: Bool
    let accountLabeler: EmailAccountLabeler
    let canLoadOlder: Bool
    let onLoadOlder: () -> Void
    let onQuickAction: (ReviewActionToken, EmailThread, EmailMailbox) -> Void

    var body: some View {
        Group {
            if threads.isEmpty {
                EmptyMailboxView(
                    isSearching: isSearching,
                    mailboxImage: mailbox.systemImage,
                    canLoadOlder: canLoadOlder,
                    onLoadOlder: onLoadOlder
                )
            } else {
                List {
                    ForEach(threads) { thread in
                        EmailQuickActionSwipe(
                            action: quickAction,
                            onPerform: { action in onQuickAction(action, thread, mailbox) }
                        ) {
                            NavigationLink(value: thread.id) {
                                EmailThreadRow(
                                    thread: thread,
                                    isSelected: false,
                                    accountLabel: accountLabeler.label(for: thread)
                                )
                            }
                        }
                        .accessibilityAction(named: Text(quickAction.displayName)) {
                            onQuickAction(quickAction, thread, mailbox)
                        }
                    }
                    if canLoadOlder {
                        LoadOlderMessagesButton(action: onLoadOlder)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: Text("Search \(mailbox.title)"))
    }
}

/// Grows the message fetch window by one step. Shown at the bottom of the
/// thread lists whenever the window is full (see
/// `WindowedEmailContent.canLoadOlder` in `EmailView.swift`).
private struct LoadOlderMessagesButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Show Older Messages", systemImage: "clock.arrow.circlepath")
                .font(.callout)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6)
    }
}

private struct EmailThreadRow: View {
    let thread: EmailThread
    let isSelected: Bool
    let accountLabel: String?

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
                Text(latest?.displayFromAddress ?? "Unknown")
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
                    .emailNotesPresentation(
                        isPresented: $showingNotes,
                        emails: thread.sortedMessages
                    )
                }
            }
            Text(latest?.subject ?? "(no subject)")
                .font(.callout)
                .fontWeight(unread > 0 ? .semibold : .regular)
                .lineLimit(1)
            if let accountLabel {
                EmailAccountBadge(label: accountLabel)
                    .lineLimit(1)
            }
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
