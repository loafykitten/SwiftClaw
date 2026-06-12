import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
import Collaboration
import Darwin
import OpenDirectory
#endif

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

        modelContext.delete(chat)
        selectedChatID = selectedChatID == chat.id ? fallback : selectedChatID
        saveChatListChange()
    }

    private func saveChatListChange() {
        do {
            try modelContext.save()
        } catch {
            assertionFailure("Couldn't save chat list change: \(error.localizedDescription)")
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
    let action: () -> Void

    @State private var isHovering = false

    private var foregroundStyle: Color {
        if role == .destructive, isHovering {
            return .red
        }

        return isHovering ? .primary : .secondary
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
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
        .help(label)
        .accessibilityLabel(label)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct ChatTranscriptView: View {
    @Environment(\.modelContext) private var modelContext

    let chat: Chat

    private var scrollTrigger: String {
        let messages = chat.visibleMessages
            .map { "\($0.id.uuidString):\($0.content.count)" }
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
                            ChatMessageRow(message: message)
                                .id(message.id.uuidString)
                        }

                        if chat.isGenerating {
                            GeneratingMessageRow()
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

            ChatComposerView(isBusy: chat.isGenerating) { input, model in
                submitMessage(input: input, model: model)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func submitMessage(input: String, model: String) -> Bool {
        guard !input.isEmpty, !chat.isGenerating else {
            return false
        }

        chat.modelSelection = model
        chat.errorMessage = nil
        chat.isGenerating = true
        chat.appendMessage(role: .user, content: input)

        do {
            try modelContext.save()
        } catch {
            chat.isGenerating = false
            chat.errorMessage = "Couldn't save your message."
            return false
        }

        Task {
            await completeChat()
        }

        return true
    }

    private func completeChat() async {
        do {
            let response = try await InferenceService.shared.complete(
                messages: chat.sortedMessages.compactMap(\.inferenceMessage),
                model: chat.modelSelection
            )

            chat.appendMessage(role: .assistant, content: response)
            chat.isGenerating = false
            chat.errorMessage = nil
        } catch {
            chat.isGenerating = false
            chat.errorMessage = error.localizedDescription
        }

        do {
            try modelContext.save()
        } catch {
            chat.errorMessage = "Couldn't save the assistant response."
        }
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

    @AppStorage(SettingsKeys.accentHue) private var accentHue = AccentColor.defaultHue
    @AppStorage(SettingsKeys.accentLightness) private var accentLightness = AccentColor.defaultLightness

    private var accent: Color {
        AccentColor.color(hue: accentHue, lightness: accentLightness)
    }

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if isUser {
                Spacer(minLength: 80)
            } else {
                AssistantAvatarView()
            }

            Text(message.content)
                .textSelection(.enabled)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(isUser ? .white : .primary)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isUser ? accent : Color.secondary.opacity(0.12))
                }
                .frame(maxWidth: 560, alignment: isUser ? .trailing : .leading)

            if isUser {
                UserAvatarView()
            } else {
                Spacer(minLength: 80)
            }
        }
    }
}

private struct GeneratingMessageRow: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            AssistantAvatarView()

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
            }

            Spacer(minLength: 80)
        }
    }
}

private struct ChatErrorView: View {
    let message: String

    var body: some View {
        HStack {
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

            Spacer(minLength: 80)
        }
    }
}

private struct AssistantAvatarView: View {
    var body: some View {
        Image("AssistantAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: ChatAvatarMetrics.size, height: ChatAvatarMetrics.size)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
            .accessibilityLabel("Assistant")
    }
}

private struct UserAvatarView: View {
    private let image = CurrentUserProfileImage.image

    var body: some View {
        ZStack {
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
        }
        .frame(width: ChatAvatarMetrics.size, height: ChatAvatarMetrics.size)
        .clipShape(Circle())
        .accessibilityLabel("User")
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

private enum CurrentUserProfileImage {
    #if os(macOS)
    static let image: NSImage? = {
        if let image = openDirectoryImage() {
            return image
        }

        return CBUserIdentity(
            posixUID: getuid(),
            authority: .default()
        )?.image?.normalizedForAvatar()
    }()

    private static func openDirectoryImage(username: String = NSUserName()) -> NSImage? {
        guard let localNode = try? ODNode(session: .default(), name: "/Local/Default"),
              let record = try? localNode.record(
                withRecordType: kODRecordTypeUsers,
                name: username,
                attributes: [
                    kODAttributeTypeJPEGPhoto,
                    kODAttributeTypePicture,
                ]
              ),
              let details = try? record.recordDetails(
                forAttributes: [
                    kODAttributeTypeJPEGPhoto,
                    kODAttributeTypePicture,
                ]
              ) else {
            return nil
        }

        if let jpegData = firstAttributeValue(
            in: details,
            for: kODAttributeTypeJPEGPhoto,
            as: Data.self
        ), let image = NSImage(data: jpegData)?.normalizedForAvatar() {
            return image
        }

        let picturePaths = attributeValues(
            in: details,
            for: kODAttributeTypePicture,
            as: String.self
        )

        for path in picturePaths {
            if let image = NSImage(contentsOfFile: path)?.normalizedForAvatar() {
                return image
            }
        }

        return nil
    }

    private static func firstAttributeValue<T>(
        in details: [AnyHashable: Any],
        for key: String,
        as type: T.Type
    ) -> T? {
        attributeValues(in: details, for: key, as: type).first
    }

    private static func attributeValues<T>(
        in details: [AnyHashable: Any],
        for key: String,
        as type: T.Type
    ) -> [T] {
        if let values = details[key] as? [T] {
            return values
        }

        if let value = details[key] as? T {
            return [value]
        }

        return []
    }
    #else
    static let image: NSImage? = nil
    #endif
}

#if os(macOS)
private extension NSImage {
    func normalizedForAvatar(pointSize: CGFloat = ChatAvatarMetrics.size) -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelSize = CGSize(width: pointSize * scale, height: pointSize * scale)
        let image = NSImage(size: pixelSize)

        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(
            in: CGRect(origin: .zero, size: pixelSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        image.unlockFocus()
        image.size = CGSize(width: pointSize, height: pointSize)

        return image
    }
}
#endif

#Preview {
    ChatsView()
}
