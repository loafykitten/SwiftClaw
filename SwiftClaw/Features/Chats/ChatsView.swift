import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#endif

struct ChatsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    var emailDispatcher: AnyHashableReviewActionDispatcher?

    @Binding private var selectedChatID: UUID?
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @State private var isShowingArchivedChats = false
    @State private var shouldShowChatListOnly = false
    @State private var compactNavigationPath: [UUID] = []
    @State private var chatSearchText = ""
    @State private var pendingCompactDelete: Chat?
    @State private var presentedError: PresentedAppError?
    #if DEBUG
    @State private var hasAppliedLaunchTranscript = false
    #endif

    private var orderedActiveChats: [Chat] {
        ChatListOrdering.sorted(chats.filter { !$0.isArchived })
    }

    private var orderedArchivedChats: [Chat] {
        ChatListOrdering.sorted(chats.filter(\.isArchived), pinnedFirst: false)
    }

    private var displayedChats: [Chat] {
        isShowingArchivedChats ? orderedArchivedChats : orderedActiveChats
    }

    private var searchableDisplayedChats: [Chat] {
        displayedChats.filter { $0.matchesSearch(chatSearchText) }
    }

    private var isSearchingChats: Bool {
        SearchQuery.isActive(chatSearchText)
    }

    private var historyTitle: String {
        isShowingArchivedChats ? "Archived" : "History"
    }

    private var emptyListKind: EmptyChatsView.Kind {
        isShowingArchivedChats ? .archived : .active
    }

    private var selectedChat: Chat? {
        guard let selectedChatID else { return nil }
        return searchableDisplayedChats.first { $0.id == selectedChatID }
    }

    private var selectedChatBinding: Binding<UUID?> {
        Binding(
            get: { selectedChatID },
            set: { newValue in
                selectedChatID = newValue
                if newValue != nil {
                    shouldShowChatListOnly = false
                }
            }
        )
    }

    init(selectedChatID: Binding<UUID?> = .constant(nil), emailDispatcher: AnyHashableReviewActionDispatcher? = nil) {
        _selectedChatID = selectedChatID
        self.emailDispatcher = emailDispatcher
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactBody
            } else {
                regularBody
            }
        }
        .toolbar {
            #if os(iOS)
            if horizontalSizeClass != .compact {
                chatToolbarItems
            }
            #else
            chatToolbarItems
            #endif
        }
        .appErrorAlert($presentedError)
    }

    private var chatToolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("New Chat", systemImage: "square.and.pencil", action: createChat)
                .help("Create a new chat")

            Button(
                isShowingArchivedChats ? "Chats" : "Archived Chats",
                systemImage: isShowingArchivedChats ? "bubble.left.and.bubble.right" : "archivebox",
                action: toggleArchivedChats
            )
            .help(isShowingArchivedChats ? "Show active chats" : "Show archived chats")
        }
    }

    private var regularBody: some View {
        HStack(spacing: 0) {
            ChatHistoryView(
                title: historyTitle,
                chats: searchableDisplayedChats,
                selectedChatID: selectedChatBinding,
                searchText: $chatSearchText,
                emptyKind: emptyListKindForCurrentSearch,
                hasUnreadMessages: { router.hasUnreadMessages(in: $0) },
                togglePin: togglePin,
                archiveChat: archiveChat,
                unarchiveChat: unarchiveChat,
                deleteChat: deleteChat
            )

            Divider()

            if let selectedChat {
                ChatTranscriptView(
                    chat: selectedChat,
                    emailDispatcherProvider: { [emailDispatcher] in
                        emailDispatcher
                    },
                    archiveChat: archiveChat,
                    unarchiveChat: unarchiveChat
                )
                    .id(selectedChat.id)
            } else {
                // The history column owns the empty/no-results messaging;
                // the detail pane only ever reports the missing selection.
                EmptyChatsView(.selection)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: selectFallbackChatIfNeeded)
        .onChange(of: searchableDisplayedChats.map(\.id)) { _, _ in
            selectFallbackChatIfNeeded()
        }
        .onChange(of: isShowingArchivedChats) { _, _ in
            selectFallbackChatIfNeeded()
        }
    }

    private var compactBody: some View {
        NavigationStack(path: $compactNavigationPath) {
            Group {
                if searchableDisplayedChats.isEmpty {
                    EmptyChatsView(emptyListKindForCurrentSearch)
                } else {
                    List {
                        ForEach(searchableDisplayedChats) { chat in
                            NavigationLink(value: chat.id) {
                                CompactChatHistoryRow(
                                    chat: chat,
                                    hasUnreadMessages: router.hasUnreadMessages(in: chat.id)
                                )
                            }
                            .swipeActions(edge: .trailing) {
                                if chat.isArchived {
                                    Button {
                                        unarchiveChat(chat)
                                    } label: {
                                        Label("Unarchive", systemImage: "archivebox")
                                    }
                                    .tint(.accentColor)
                                } else {
                                    Button(role: .destructive) {
                                        pendingCompactDelete = chat
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }

                                    Button {
                                        archiveChat(chat)
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(.secondary)

                                    Button {
                                        togglePin(chat)
                                    } label: {
                                        Label(
                                            chat.isPinned ? "Unpin" : "Pin",
                                            systemImage: chat.isPinned ? "pin.slash" : "pin"
                                        )
                                    }
                                    .tint(.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(isShowingArchivedChats ? "Archived Chats" : "Chats")
            .searchable(text: $chatSearchText, prompt: "Search Chats")
            .toolbar { chatToolbarItems }
            .navigationDestination(for: UUID.self) { chatID in
                if let chat = displayedChats.first(where: { $0.id == chatID }) {
                    ChatTranscriptView(
                        chat: chat,
                        emailDispatcherProvider: { [emailDispatcher] in
                            emailDispatcher
                        },
                        archiveChat: archiveChat,
                        unarchiveChat: unarchiveChat
                    )
                    .id(chat.id)
                    .navigationTitle(chat.title)
                    .modifier(CompactChatTranscriptChrome(
                        chat: chat,
                        archiveChat: archiveChat,
                        unarchiveChat: unarchiveChat
                    ))
                } else {
                    EmptyChatsView(emptyListKind)
                }
            }
        }
        .onChange(of: compactNavigationPath) { _, path in
            // Keep the router's notion of the open chat in sync with the
            // pushed transcript so unread state clears correctly.
            if let chatID = path.last {
                selectedChatID = chatID
                shouldShowChatListOnly = false
            }
        }
        .onAppear(perform: openFirstChatIfRequested)
        .confirmingAction(
            item: $pendingCompactDelete,
            copy: ConfirmationDialogCopy(
                title: "Delete this chat?",
                actionTitle: "Delete",
                message: "The chat and its image attachments will be removed from SwiftClaw."
            ),
            action: deleteChat
        )
    }

    private var emptyListKindForCurrentSearch: EmptyChatsView.Kind {
        isSearchingChats ? .search : emptyListKind
    }

    /// `-SwiftClawOpenFirstChat` pushes the most recent chat's transcript in
    /// compact widths, so simulator runs can exercise it without tapping.
    private func openFirstChatIfRequested() {
        #if DEBUG
        guard !hasAppliedLaunchTranscript else { return }
        hasAppliedLaunchTranscript = true

        guard ProcessInfo.processInfo.arguments.contains("-SwiftClawOpenFirstChat"),
              let chat = displayedChats.first else { return }

        selectedChatID = chat.id
        compactNavigationPath = [chat.id]
        #endif
    }

    private func selectFallbackChatIfNeeded() {
        guard !shouldShowChatListOnly else { return }
        guard selectedChatID == nil || !searchableDisplayedChats.contains(where: { $0.id == selectedChatID }) else {
            return
        }

        selectedChatID = searchableDisplayedChats.first?.id
    }

    private func createChat() {
        isShowingArchivedChats = false
        chatSearchText = ""
        shouldShowChatListOnly = false
        let chat = Chat(
            title: "New Chat",
            modelSelection: swiftModel,
            isGenerating: false
        )
        modelContext.insert(chat)

        do {
            try modelContext.save()
        } catch {
            modelContext.delete(chat)
            presentedError = PresentedAppError(ChatCreationError.saveFailed(error), title: "Couldn't create chat")
            return
        }

        selectedChatID = chat.id
        if horizontalSizeClass == .compact {
            compactNavigationPath = [chat.id]
        }
    }

    private func toggleArchivedChats() {
        isShowingArchivedChats.toggle()
        chatSearchText = ""
        shouldShowChatListOnly = false
        compactNavigationPath.removeAll()
    }

    private func togglePin(_ chat: Chat) {
        guard !chat.isArchived else { return }
        chat.isPinned.toggle()
        saveChatListChange()
    }

    private func archiveChat(_ chat: Chat) {
        guard !chat.isArchived else { return }
        let wasViewingChat = selectedChatID == chat.id || compactNavigationPath.last == chat.id
        chat.isArchived = true
        chat.isPinned = false
        router.clearUnreadMessages(in: chat.id)

        if wasViewingChat {
            shouldShowChatListOnly = true
            selectedChatID = nil
            compactNavigationPath.removeAll()
        }

        saveChatListChange()
    }

    private func unarchiveChat(_ chat: Chat) {
        guard chat.isArchived else { return }
        chat.isArchived = false
        chat.isPinned = false
        isShowingArchivedChats = false
        shouldShowChatListOnly = false
        selectedChatID = chat.id
        if horizontalSizeClass == .compact {
            compactNavigationPath = [chat.id]
        }

        saveChatListChange()
    }

    private func deleteChat(_ chat: Chat) {
        let fallback = searchableDisplayedChats.first { $0.id != chat.id }?.id
        let chatID = chat.id

        ChatTaskCoordinator.shared.cancelTasks(for: chatID)
        modelContext.delete(chat)
        router.clearUnreadMessages(in: chatID)
        selectedChatID = selectedChatID == chat.id ? fallback : selectedChatID
        if saveChatListChange() {
            ImageAttachmentStore.shared.deleteImages(for: chatID)
        }
    }

    @discardableResult
    private func saveChatListChange() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            assertionFailure("Couldn't save chat list change: \(error.localizedDescription)")
            return false
        }
    }
}

private struct CompactChatHistoryRow: View {
    let chat: Chat
    let hasUnreadMessages: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if hasUnreadMessages {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("New messages")
                }

                Text(chat.title)
                    .font(.body)
                    .fontWeight(hasUnreadMessages ? .semibold : .regular)
                    .lineLimit(2)

                if chat.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if chat.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(chat.modelSelection)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(chat.latestVisibleMessageDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct ChatHistoryView: View {
    let title: String
    let chats: [Chat]
    @Binding var selectedChatID: UUID?
    @Binding var searchText: String
    let emptyKind: EmptyChatsView.Kind
    let hasUnreadMessages: (UUID) -> Bool
    let togglePin: (Chat) -> Void
    let archiveChat: (Chat) -> Void
    let unarchiveChat: (Chat) -> Void
    let deleteChat: (Chat) -> Void

    @State private var pendingDelete: Chat?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if chats.isEmpty {
                EmptyChatsView(emptyKind)
            } else {
                #if os(macOS)
                List(selection: $selectedChatID) {
                    ForEach(chats) { chat in
                        row(for: chat)
                            .tag(chat.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    }
                }
                .listStyle(.sidebar)
                #else
                List {
                    ForEach(chats) { chat in
                        Button {
                            selectedChatID = chat.id
                        } label: {
                            row(for: chat)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    }
                }
                .listStyle(.sidebar)
                #endif
            }
        }
        .frame(width: 260)
        .searchable(text: $searchText, prompt: "Search Chats")
        .confirmingAction(
            item: $pendingDelete,
            copy: ConfirmationDialogCopy(
                title: "Delete this chat?",
                actionTitle: "Delete",
                message: "The chat and its image attachments will be removed from SwiftClaw."
            ),
            action: deleteChat
        )
    }

    private func row(for chat: Chat) -> ChatHistoryRow {
        ChatHistoryRow(
            chat: chat,
            isSelected: chat.id == selectedChatID,
            hasUnreadMessages: hasUnreadMessages(chat.id),
            togglePin: { togglePin(chat) },
            archiveChat: { archiveChat(chat) },
            unarchiveChat: { unarchiveChat(chat) },
            deleteChat: { pendingDelete = chat }
        )
    }
}

private struct ChatHistoryRow: View {
    let chat: Chat
    let isSelected: Bool
    let hasUnreadMessages: Bool
    let togglePin: () -> Void
    let archiveChat: () -> Void
    let unarchiveChat: () -> Void
    let deleteChat: () -> Void

    @State private var isHovering = false

    private var showsActions: Bool {
        isSelected || isHovering || chat.isPinned
    }

    private var actionWidth: CGFloat {
        chat.isArchived ? 46 : 70
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if hasUnreadMessages {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("New messages")
                    }

                    Text(chat.title)
                        .font(.callout)
                        .fontWeight(isSelected || hasUnreadMessages ? .semibold : .regular)
                        .lineLimit(2)

                    if chat.isGenerating {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12, height: 12)
                    }
                }

                Text(chat.modelSelection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(chat.latestVisibleMessageDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())

            HStack(spacing: 2) {
                if chat.isArchived {
                    ChatHistoryActionButton(
                        systemName: "archivebox",
                        label: "Unarchive chat",
                        action: unarchiveChat
                    )

                    ChatHistoryActionButton(
                        systemName: "trash",
                        label: "Delete chat",
                        role: .destructive,
                        action: deleteChat
                    )
                } else {
                    ChatHistoryActionButton(
                        systemName: chat.isPinned ? "pin.fill" : "pin",
                        label: chat.isPinned ? "Unpin chat" : "Pin chat",
                        action: togglePin
                    )

                    ChatHistoryActionButton(
                        systemName: "archivebox",
                        label: "Archive chat",
                        action: archiveChat
                    )

                    ChatHistoryActionButton(
                        systemName: "trash",
                        label: "Delete chat",
                        role: .destructive,
                        action: deleteChat
                    )
                }
            }
            .opacity(showsActions ? 1 : 0)
            .disabled(!showsActions)
            .accessibilityHidden(!showsActions)
            .frame(width: actionWidth, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sidebarRowState(isEmphasized: hasUnreadMessages)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ChatHistoryActionButton: View {
    let systemName: String
    let label: String
    var role: ButtonRole?
    let action: () -> Void

    @State private var isHovering = false

    private var foregroundStyle: Color {
        if role == .destructive, isHovering {
            return .red
        }

        return isHovering ? .primary : .secondary
    }

    private var effectiveSystemName: String {
        systemName
    }

    private var effectiveLabel: String {
        label
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: effectiveSystemName)
                .frame(width: 18, height: 18)
                .padding(3)
                .foregroundStyle(foregroundStyle)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovering ? Color.secondary.opacity(0.14) : .clear)
                }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(effectiveLabel)
        .accessibilityLabel(effectiveLabel)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private enum ChatTranscriptItem: Identifiable {
    case daySeparator(Date)
    case message(ChatMessage)

    var id: String {
        switch self {
        case .daySeparator(let date):
            return "day-\(Int(date.timeIntervalSince1970))"
        case .message(let message):
            return message.id.uuidString
        }
    }
}

private struct ChatDaySeparator: View {
    let date: Date

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.5)

            Text(ChatDaySeparatorFormatter.label(for: date))
                .font(.caption)
                .foregroundStyle(.secondary)

            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.5)
        }
        .padding(.vertical, 2)
        .accessibilityLabel("Date separator")
        .accessibilityValue(ChatDaySeparatorFormatter.label(for: date))
    }
}

private struct ChatTranscriptView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext

    let chat: Chat
    let emailDispatcherProvider: () -> AnyHashableReviewActionDispatcher?
    let archiveChat: (Chat) -> Void
    let unarchiveChat: (Chat) -> Void
    @State private var previewSelection: ImageAttachmentPreviewSelection?
    @State private var presentedError: PresentedAppError?
    @State private var scrollTask: Task<Void, Never>?

    private var scrollTrigger: String {
        let messages = chat.visibleMessages
            .map { "\($0.id.uuidString):\($0.content.count):\($0.imageAttachments.count)" }
            .joined(separator: "|")
        let error = chat.errorMessage ?? ""

        return "\(chat.id.uuidString)|\(messages)|\(chat.isGenerating)|\(error.count)"
    }

    private var transcriptItems: [ChatTranscriptItem] {
        let messages = chat.visibleMessages
        var separatorDays = ChatDaySeparatorFormatter
            .separatorDays(for: messages.map(\.createdAt))
            .makeIterator()
        var nextSeparator = separatorDays.next()
        var items: [ChatTranscriptItem] = []

        for message in messages {
            let day = Calendar.current.startOfDay(for: message.createdAt)

            if day == nextSeparator {
                items.append(.daySeparator(day))
                nextSeparator = separatorDays.next()
            }

            items.append(.message(message))
        }

        return items
    }

    private var composerHorizontalPadding: CGFloat {
        #if os(iOS)
        horizontalSizeClass == .compact ? 18 : 24
        #else
        24
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            // In compact widths the navigation bar carries the title, model,
            // and title actions, so the inline header would be redundant.
            if horizontalSizeClass != .compact {
                ChatHeaderView(
                    chat: chat,
                    archiveChat: archiveChat,
                    unarchiveChat: unarchiveChat
                )

                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(transcriptItems) { item in
                            switch item {
                            case .daySeparator(let day):
                                ChatDaySeparator(date: day)
                            case .message(let message):
                                ChatMessageRow(
                                    message: message,
                                    emailDispatcher: emailDispatcherProvider(),
                                    showImagePreview: showImagePreview
                                )
                                    .id(message.id.uuidString)
                            }
                        }

                        if chat.isGenerating {
                            GeneratingMessageRow(chatID: chat.id)
                                .id("generating")
                        }

                        if let errorMessage = chat.errorMessage {
                            ChatErrorView(message: errorMessage)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(ChatScrollTarget.bottom)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .chatComposerScrollDismissesKeyboard()
                .chatComposerDismissKeyboardOnTap()
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: scrollTrigger) { _, _ in
                    scrollToBottom(proxy)
                }
                .safeAreaBar(edge: .bottom) {
                    if !chat.isArchived {
                        ChatComposerView(
                            isBusy: chat.isGenerating,
                            chatReasoningEffort: chat.reasoningEffort,
                            onReasoningEffortChange: { effort in
                                chat.reasoningEffort = effort
                                try? modelContext.save()
                            }
                        ) { submission in
                            submitMessage(submission)
                        }
                        .padding(.horizontal, composerHorizontalPadding)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .imageAttachmentPreviewOverlay(selection: $previewSelection)
        .appErrorAlert($presentedError)
        .onDisappear {
            scrollTask?.cancel()
            scrollTask = nil
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(ChatScrollTarget.bottom, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(ChatScrollTarget.bottom, anchor: .bottom)
            }
            guard !Task.isCancelled else { return }
            scrollTask = nil
        }
    }

    private func showImagePreview(
        attachments: [ImageAttachmentRecord],
        initialIndex: Int
    ) {
        previewSelection = ImageAttachmentPreviewSelection(
            attachments: attachments,
            initialIndex: initialIndex
        )
    }

    private func submitMessage(_ submission: ChatComposerSubmission) -> Bool {
        let input = submission.text
        guard !input.isEmpty, !chat.isGenerating, !chat.isArchived else {
            return false
        }

        let finalizedAttachments: [ImageAttachmentRecord]
        do {
            finalizedAttachments = try ImageAttachmentStore.shared.finalizeDraftAttachments(
                submission.imageAttachments,
                for: chat.id
            )
        } catch {
            presentSubmissionError(.attachmentFinalizationFailed(error))
            return false
        }

        chat.modelSelection = submission.model
        chat.errorMessage = nil
        chat.isGenerating = true
        chat.appendMessage(
            role: .user,
            content: input,
            imageAttachments: finalizedAttachments
        )

        do {
            try modelContext.save()
            ImageAttachmentStore.shared.deleteDraftAttachments(submission.imageAttachments)
        } catch {
            ImageAttachmentStore.shared.deleteAttachments(finalizedAttachments)
            chat.isGenerating = false
            presentSubmissionError(.saveFailed(error))
            return false
        }

        ChatTaskCoordinator.shared.completeChat(
            chat,
            in: modelContext,
            allowInvestigation: submission.isInvestigationEnabled,
            supportsImages: submission.supportsImages,
            reasoningEffort: submission.reasoningEffort
        )

        return true
    }

    private func presentSubmissionError(_ error: ChatSubmissionError) {
        chat.errorMessage = error.errorDescription
        presentedError = PresentedAppError(error, title: "Couldn't send message")
    }
}

private enum ChatSubmissionError: LocalizedError {
    case attachmentFinalizationFailed(any Error)
    case saveFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .attachmentFinalizationFailed:
            "Couldn't attach the selected images."
        case .saveFailed:
            "Couldn't save your message."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .attachmentFinalizationFailed(let error):
            "Check that the image files still exist and try again. Details: \(error.localizedDescription)"
        case .saveFailed(let error):
            "Your draft attachments were rolled back. Try sending again. Details: \(error.localizedDescription)"
        }
    }
}

private enum ChatScrollTarget {
    static let bottom = "chat-scroll-bottom"
}

private struct ChatHeaderView: View {
    let chat: Chat
    let archiveChat: (Chat) -> Void
    let unarchiveChat: (Chat) -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @State private var isGeneratingTitle = false
    @State private var titleTask: Task<Void, Never>?
    @FocusState private var isTitleFieldFocused: Bool

    private var isEmailReviewChat: Bool {
        chat.isEmailReviewChat
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if isEditingTitle {
                    TextField("Chat title", text: $draftTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .focused($isTitleFieldFocused)
                        .onSubmit { commitTitleEdit() }
                        #if os(macOS)
                        .onExitCommand { cancelTitleEdit() }
                        #endif
                } else {
                    Text(chat.title)
                        .font(.headline)
                        .lineLimit(1)
                }

                Text(chat.modelSelection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isGeneratingTitle {
                ProgressView()
                    .controlSize(.small)
                    .help("Generating title")
            }

            if chat.isGenerating {
                ProgressView()
                    .controlSize(.small)
            }

            Menu {
                Button("Rename", systemImage: "square.and.pencil", action: beginTitleEdit)
                    .disabled(chat.isGenerating)

                if chat.isArchived {
                    Button("Unarchive", systemImage: "archivebox") {
                        unarchiveChat(chat)
                    }
                } else {
                    Button("Archive", systemImage: "archivebox") {
                        archiveChat(chat)
                    }

                    if !isEmailReviewChat {
                        Divider()
                        Button("Regenerate Title", systemImage: "sparkles", action: startRegeneratingTitle)
                            .disabled(chat.isGenerating || isGeneratingTitle)
                    }
                }
            } label: {
                Label("Chat Options", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .help("Chat options")
            .disabled(isEditingTitle)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .onChange(of: isEditingTitle) { _, isEditing in
            if isEditing {
                isTitleFieldFocused = true
            }
        }
        .onDisappear {
            titleTask?.cancel()
            titleTask = nil
        }
    }

    private func beginTitleEdit() {
        draftTitle = chat.title
        isEditingTitle = true
    }

    private func commitTitleEdit() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelTitleEdit()
            return
        }

        chat.title = trimmed
        try? modelContext.save()
        isEditingTitle = false
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
    }

    private func startRegeneratingTitle() {
        guard !isGeneratingTitle else { return }
        titleTask?.cancel()
        titleTask = Task { @MainActor in
            await regenerateTitle()
            guard !Task.isCancelled else { return }
            titleTask = nil
        }
    }

    private func regenerateTitle() async {
        isGeneratingTitle = true
        defer {
            if !Task.isCancelled {
                isGeneratingTitle = false
            }
        }

        await ChatTitleService.regenerateTitle(for: chat, in: modelContext)
    }
}

/// Navigation-bar chrome for the pushed transcript in compact widths: inline
/// title with the model as subtitle, plus a menu carrying the rename /
/// regenerate-title actions that `ChatHeaderView` offers in regular widths.
private struct CompactChatTranscriptChrome: ViewModifier {
    let chat: Chat
    let archiveChat: (Chat) -> Void
    let unarchiveChat: (Chat) -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var isRenamePresented = false
    @State private var draftTitle = ""
    @State private var isGeneratingTitle = false
    @State private var titleTask: Task<Void, Never>?

    private var isEmailReviewChat: Bool {
        chat.isEmailReviewChat
    }

    func body(content: Content) -> some View {
        content
            .toolbarTitleDisplayMode(.inline)
            .navigationSubtitle(chat.modelSelection)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Rename", systemImage: "square.and.pencil") {
                            draftTitle = chat.title
                            isRenamePresented = true
                        }
                        .disabled(chat.isGenerating)

                        if chat.isArchived {
                            Button("Unarchive", systemImage: "archivebox") {
                                unarchiveChat(chat)
                            }
                        } else {
                            Button("Archive", systemImage: "archivebox") {
                                archiveChat(chat)
                            }

                            if !isEmailReviewChat {
                                Divider()
                                Button("Regenerate Title", systemImage: "sparkles", action: startRegeneratingTitle)
                                    .disabled(chat.isGenerating || isGeneratingTitle)
                            }
                        }
                    } label: {
                        if isGeneratingTitle {
                            ProgressView()
                        } else {
                            Label("Chat Options", systemImage: "ellipsis")
                        }
                    }
                }
            }
            .alert("Rename Chat", isPresented: $isRenamePresented) {
                TextField("Chat title", text: $draftTitle)
                Button("Cancel", role: .cancel) {}
                Button("Save", action: commitRename)
            }
            .onDisappear {
                titleTask?.cancel()
                titleTask = nil
            }
    }

    private func commitRename() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.title = trimmed
        try? modelContext.save()
    }

    private func startRegeneratingTitle() {
        guard !isGeneratingTitle else { return }
        titleTask?.cancel()
        titleTask = Task { @MainActor in
            isGeneratingTitle = true
            defer {
                if !Task.isCancelled {
                    isGeneratingTitle = false
                }
            }
            await ChatTitleService.regenerateTitle(for: chat, in: modelContext)
            guard !Task.isCancelled else { return }
            titleTask = nil
        }
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    var emailDispatcher: AnyHashableReviewActionDispatcher?
    let showImagePreview: ([ImageAttachmentRecord], Int) -> Void

    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext

    @AppStorage(SettingsKeys.quoteAccentHue) private var quoteAccentHue = QuoteAccent.defaultQuoteHue
    @AppStorage(SettingsKeys.quoteAccentLightness) private var quoteAccentLightness = QuoteAccent.defaultQuoteLightness

    private var quoteAccent: Color {
        QuoteAccent.color(hue: quoteAccentHue, lightness: quoteAccentLightness)
    }

    private var isUser: Bool {
        message.role == .user
    }

    private var imageAttachments: [ImageAttachmentRecord] {
        isUser ? message.imageAttachments : []
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser {
                Spacer(minLength: 0)
            } else {
                AssistantAvatarView()
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                if let reviewCard = message.reviewCard {
                    ReviewCardRendererRegistry.shared.makeView(
                        for: reviewCard,
                        dispatcherProvider: { [emailDispatcher] _ in emailDispatcher },
                        onItemActioned: { itemID in
                            guard var updated = message.reviewCard else { return }
                            updated.items.removeAll { $0.id == itemID }
                            message.reviewCard = updated
                            try? modelContext.save()
                        },
                        onItemView: { emailID in
                            router.showEmail(emailID)
                        },
                        onRefreshAnalysis: {
                            await EmailWorkflowManager.shared.reviewNow(appendingTo: message.chat?.id)
                        }
                    )
                    .frame(maxWidth: ChatBubbleLayout.maxWidth, alignment: .leading)
                }

                if !imageAttachments.isEmpty {
                    ImageAttachmentFanStack(
                        attachments: imageAttachments,
                        onSelect: { showImagePreview(imageAttachments, $0) }
                    )
                }

                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ChatMarkdownView(
                        content: message.content,
                        defaultForeground: isUser ? .white : .primary,
                        codeAccent: isUser ? .white : Color.accentColor,
                        quoteAccent: quoteAccent,
                        linkAccent: isUser ? .white : Color.accentColor,
                        maximumContentWidth: ChatBubbleLayout.contentMaxWidth
                    )
                    .textSelection(.enabled)
                    .padding(.horizontal, ChatBubbleLayout.horizontalPadding)
                    .padding(.vertical, ChatBubbleLayout.verticalPadding)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isUser ? Color.accentColor : Color.secondary.opacity(0.12))
                    }
                }

                Text(
                    message.createdAt,
                    format: Date.FormatStyle(date: .omitted, time: .shortened)
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Sent at \(message.createdAt.formatted(date: .omitted, time: .shortened))")
            }
                .frame(maxWidth: ChatBubbleLayout.maxWidth, alignment: isUser ? .trailing : .leading)
                .padding(isUser ? .trailing : .leading, ChatBubbleLayout.avatarSpacing)

            if isUser {
                UserAvatarView()
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func printRawMessage() {
        #if DEBUG
        print("""

        --- Raw chat message (\(message.role.rawValue)) ---
        \(message.content)
        --- End raw chat message ---

        """)
        #endif
    }
}

private struct GeneratingMessageRow: View {
    let chatID: UUID

    private var statusLabel: String? {
        ToolActivityMonitor.shared.statusLabel(forChatID: chatID)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            AssistantAvatarView()

            HStack(spacing: 8) {
                if let statusLabel {
                    Text(statusLabel)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                AnimatedEllipsisView()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
            }
            .padding(.leading, ChatBubbleLayout.avatarSpacing)

            Spacer(minLength: 0)
        }
    }
}

/// Three dots pulsing in sequence — the default "assistant is working"
/// indicator shown while a response generates.
private struct AnimatedEllipsisView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = sin((time * 2.2 - Double(index) * 0.4) * .pi)
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * max(0, wave))
                }
            }
        }
        .accessibilityLabel("Generating response")
    }
}

private struct ChatErrorView: View {
    let message: String

    var body: some View {
        HStack(spacing: 0) {
            AssistantAvatarView()

            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.12))
                }
                .padding(.leading, ChatBubbleLayout.avatarSpacing)

            Spacer(minLength: 0)
        }
    }
}

private struct AssistantAvatarView: View {
    @AppStorage(SettingsKeys.assistantAvatarData) private var avatarData = Data()
    @AppStorage(SettingsKeys.assistantDisplayName) private var displayName = AssistantPersona.defaultDisplayName

    #if os(macOS) || os(iOS)
    private var image: PlatformImage? {
        AssistantPersona.avatarImage(
            overrideData: avatarData.isEmpty ? nil : avatarData
        )
    }
    #endif

    private var accessibilityName: String {
        AssistantPersona.sanitizedDisplayName(displayName) ?? AssistantPersona.defaultDisplayName
    }

    var body: some View {
        ZStack {
            #if os(macOS)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
            #elseif os(iOS)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
            #else
            fallback
            #endif
        }
        .frame(width: ChatAvatarMetrics.size, height: ChatAvatarMetrics.size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityLabel(accessibilityName)
    }

    private var fallback: some View {
        Image("AssistantAvatar")
            .resizable()
            .scaledToFill()
    }
}

private struct UserAvatarView: View {
    @AppStorage(SettingsKeys.personaAvatarData) private var avatarData = Data()
    @AppStorage(SettingsKeys.personaDisplayName) private var displayNameOverride = ""

    #if os(macOS) || os(iOS)
    private var image: PlatformImage? {
        PersonaProfile.avatarImage(
            overrideData: avatarData.isEmpty ? nil : avatarData,
            pointSize: ChatAvatarMetrics.size
        )
    }
    #endif

    private var displayName: String {
        PersonaProfile.sanitizedDisplayName(displayNameOverride) ?? PersonaProfile.detectedDisplayName
    }

    var body: some View {
        AppSettingsButton(section: .persona) {
            avatarContent
        }
        .buttonStyle(.plain)
        .help("Open Persona settings")
        .accessibilityLabel(displayName)
        .accessibilityHint("Opens Persona settings")
    }

    private var avatarContent: some View {
        ZStack {
            #if os(macOS)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(1)
            }
            #elseif os(iOS)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(1)
            }
            #else
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(1)
            #endif
        }
        .frame(width: ChatAvatarMetrics.size, height: ChatAvatarMetrics.size)
        .clipShape(Circle())
        .contentShape(Circle())
    }
}

private enum ChatAvatarMetrics {
    static let size: CGFloat = 38
}

private struct EmptyChatsView: View {
    enum Kind {
        case active
        case archived
        case selection
        case search
    }

    let kind: Kind

    init(_ kind: Kind = .active) {
        self.kind = kind
    }

    var body: some View {
        switch kind {
        case .active:
            ContentUnavailableView(
                "No Chats Yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Create a chat to start a new conversation.")
            )
        case .archived:
            ContentUnavailableView(
                "No Archived Chats",
                systemImage: "archivebox",
                description: Text("Archived chats will appear here.")
            )
        case .selection:
            ContentUnavailableView("No Chat Selected", systemImage: "bubble.left")
        case .search:
            ContentUnavailableView.search
        }
    }
}

private enum ChatCreationError: LocalizedError {
    case saveFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .saveFailed:
            "Couldn't create the chat."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .saveFailed(let error):
            "Try again. Details: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ChatsView()
        .environment(AppRouter.shared)
}
