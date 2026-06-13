import SwiftUI
import SwiftData

struct ChatsView: View {
    @Environment(\.modelContext) private var modelContext

    @Binding private var selectedChatID: UUID?
    @Query(sort: \Chat.updatedAt, order: .reverse) private var chats: [Chat]

    private var orderedChats: [Chat] {
        chats.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }

            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private var selectedChat: Chat? {
        if let selectedChatID,
           let chat = orderedChats.first(where: { $0.id == selectedChatID }) {
            return chat
        }

        return orderedChats.first
    }

    init(selectedChatID: Binding<UUID?> = .constant(nil)) {
        _selectedChatID = selectedChatID
    }

    var body: some View {
        HStack(spacing: 0) {
            ChatHistoryView(
                chats: orderedChats,
                selectedChatID: selectedChat?.id,
                selectChat: { selectedChatID = $0 },
                togglePin: togglePin,
                deleteChat: deleteChat
            )

            Divider()

            if let selectedChat {
                ChatTranscriptView(chat: selectedChat)
                    .id(selectedChat.id)
            } else {
                EmptyChatsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: selectFallbackChatIfNeeded)
        .onChange(of: chats.map(\.id)) { _, _ in
            selectFallbackChatIfNeeded()
        }
    }

    private func selectFallbackChatIfNeeded() {
        guard selectedChatID == nil || !chats.contains(where: { $0.id == selectedChatID }) else {
            return
        }

        selectedChatID = orderedChats.first?.id
    }

    private func togglePin(_ chat: Chat) {
        chat.isPinned.toggle()
        saveChatListChange()
    }

    private func deleteChat(_ chat: Chat) {
        let fallback = orderedChats.first { $0.id != chat.id }?.id
        let chatID = chat.id

        modelContext.delete(chat)
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

private struct ChatHistoryView: View {
    let chats: [Chat]
    let selectedChatID: UUID?
    let selectChat: (UUID) -> Void
    let togglePin: (Chat) -> Void
    let deleteChat: (Chat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(chats) { chat in
                        ChatHistoryRow(
                            chat: chat,
                            isSelected: chat.id == selectedChatID,
                            selectChat: { selectChat(chat.id) },
                            togglePin: { togglePin(chat) },
                            deleteChat: { deleteChat(chat) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 260)
        .background(.background.secondary)
    }
}

private struct ChatHistoryRow: View {
    let chat: Chat
    let isSelected: Bool
    let selectChat: () -> Void
    let togglePin: () -> Void
    let deleteChat: () -> Void

    @State private var isHovering = false

    private var showsActions: Bool {
        isSelected || isHovering || chat.isPinned
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(action: selectChat) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(chat.title)
                            .font(.callout)
                            .fontWeight(isSelected ? .semibold : .regular)
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

                    Text(chat.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 2) {
                ChatHistoryActionButton(
                    systemName: chat.isPinned ? "pin.fill" : "pin",
                    label: chat.isPinned ? "Unpin chat" : "Pin chat",
                    action: togglePin
                )

                ChatHistoryActionButton(
                    systemName: "trash",
                    label: "Delete chat",
                    role: .destructive,
                    requiresSecondClick: true,
                    action: deleteChat
                )
            }
            .opacity(showsActions ? 1 : 0)
            .disabled(!showsActions)
            .accessibilityHidden(!showsActions)
            .frame(width: 46, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ChatHistoryActionButton: View {
    let systemName: String
    let label: String
    var role: ButtonRole?
    var requiresSecondClick = false
    let action: () -> Void

    @State private var isHovering = false
    @State private var isWaitingForSecondClick = false
    @State private var secondClickResetTask: Task<Void, Never>?

    private var foregroundStyle: Color {
        if role == .destructive, isWaitingForSecondClick {
            return .red
        }

        if role == .destructive, isHovering {
            return .red
        }

        return isHovering ? .primary : .secondary
    }

    private var effectiveSystemName: String {
        isWaitingForSecondClick ? "\(systemName).fill" : systemName
    }

    private var effectiveLabel: String {
        isWaitingForSecondClick ? "Click again to \(label.lowercased())" : label
    }

    var body: some View {
        Button(role: role, action: performAction) {
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
        .onHover { isHovering in
            self.isHovering = isHovering
            if !isHovering {
                cancelSecondClickRequirement()
            }
        }
        .onDisappear(perform: cancelSecondClickRequirement)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isWaitingForSecondClick)
    }

    private func performAction() {
        guard requiresSecondClick else {
            action()
            return
        }

        guard isWaitingForSecondClick else {
            waitForSecondClick()
            return
        }

        cancelSecondClickRequirement()
        action()
    }

    private func waitForSecondClick() {
        isWaitingForSecondClick = true
        secondClickResetTask?.cancel()
        secondClickResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else {
                return
            }

            isWaitingForSecondClick = false
            secondClickResetTask = nil
        }
    }

    private func cancelSecondClickRequirement() {
        isWaitingForSecondClick = false
        secondClickResetTask?.cancel()
        secondClickResetTask = nil
    }
}

private struct ChatTranscriptView: View {
    @Environment(\.modelContext) private var modelContext

    let chat: Chat
    @State private var previewSelection: ImageAttachmentPreviewSelection?

    private var scrollTrigger: String {
        let messages = chat.visibleMessages
            .map { "\($0.id.uuidString):\($0.content.count):\($0.imageAttachments.count)" }
            .joined(separator: "|")
        let error = chat.errorMessage ?? ""

        return "\(chat.id.uuidString)|\(messages)|\(chat.isGenerating)|\(error.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderView(chat: chat)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(chat.visibleMessages) { message in
                            ChatMessageRow(
                                message: message,
                                showImagePreview: showImagePreview
                            )
                                .id(message.id.uuidString)
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
                .onAppear {
                    scrollToBottom(proxy, animated: false)
                }
                .onChange(of: scrollTrigger) { _, _ in
                    scrollToBottom(proxy)
                }
            }

            ChatComposerView(isBusy: chat.isGenerating) { submission in
                submitMessage(submission)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .imageAttachmentPreviewOverlay(selection: $previewSelection)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        Task { @MainActor in
            await Task.yield()

            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(ChatScrollTarget.bottom, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(ChatScrollTarget.bottom, anchor: .bottom)
            }
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
        guard !input.isEmpty, !chat.isGenerating else {
            return false
        }

        let finalizedAttachments: [ImageAttachmentRecord]
        do {
            finalizedAttachments = try ImageAttachmentStore.shared.finalizeDraftAttachments(
                submission.imageAttachments,
                for: chat.id
            )
        } catch {
            chat.errorMessage = error.localizedDescription
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
            chat.errorMessage = "Couldn't save your message."
            return false
        }

        Task {
            await ChatCompletionService.completeChat(
                chat,
                in: modelContext,
                allowInvestigation: submission.isInvestigationEnabled,
                supportsImages: submission.supportsImages,
                reasoningEffort: submission.reasoningEffort
            )
        }

        return true
    }
}

private enum ChatScrollTarget {
    static let bottom = "chat-scroll-bottom"
}

private struct ChatHeaderView: View {
    let chat: Chat

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(chat.modelSelection)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if chat.isGenerating {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    let showImagePreview: ([ImageAttachmentRecord], Int) -> Void

    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentLightness) private var accentLightness = AccentColor.defaultLightness
    @AppStorage(SettingsKeys.quoteAccentHue) private var quoteAccentHue = AccentColor.defaultQuoteHue
    @AppStorage(SettingsKeys.quoteAccentLightness) private var quoteAccentLightness = AccentColor.defaultQuoteLightness

    private var accent: Color {
        AccentColor.color(hue: accentHue, lightness: accentLightness)
    }

    private var quoteAccent: Color {
        AccentColor.color(hue: quoteAccentHue, lightness: quoteAccentLightness)
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
                if !imageAttachments.isEmpty {
                    ImageAttachmentFanStack(
                        attachments: imageAttachments,
                        onSelect: { showImagePreview(imageAttachments, $0) }
                    )
                }

                ChatMarkdownView(
                    content: message.content,
                    defaultForeground: isUser ? .white : .primary,
                    codeAccent: isUser ? .white : accent,
                    quoteAccent: quoteAccent,
                    linkAccent: isUser ? .white : accent,
                    maximumContentWidth: ChatBubbleLayout.contentMaxWidth
                )
                .textSelection(.enabled)
                .padding(.horizontal, ChatBubbleLayout.horizontalPadding)
                .padding(.vertical, ChatBubbleLayout.verticalPadding)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isUser ? accent : Color.secondary.opacity(0.12))
                }
            }
                .frame(maxWidth: ChatBubbleLayout.maxWidth, alignment: isUser ? .trailing : .leading)
                .padding(isUser ? .trailing : .leading, ChatBubbleLayout.avatarSpacing)
                .onAppear {
                    printRawMessage()
                }
                .onChange(of: message.content) { _, _ in
                    printRawMessage()
                }

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

    #if os(macOS)
    private var image: NSImage? {
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

    #if os(macOS)
    private var image: NSImage? {
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
        .accessibilityLabel(displayName)
    }
}

private enum ChatAvatarMetrics {
    static let size: CGFloat = 38
}

private struct EmptyChatsView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("No chats yet")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Start one from Home.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ChatsView()
}
