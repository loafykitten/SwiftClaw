import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var selectedNavigationItem: NavigationItem? = .home
    var selectedChatID: UUID?
    var pendingSettingsSection: SettingsSection?
    private(set) var unreadChatIDs: Set<UUID> = []
    var pendingEmailViewID: UUID?

    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var notificationBridgeUseCount = 0

    private init() {}

    func startNotificationBridge() {
        notificationBridgeUseCount += 1
        guard notificationObservers.isEmpty else { return }

        let chatCreatedObserver = NotificationCenter.default.addObserver(
            forName: .emailReviewChatCreated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let chatID = notification.userInfo?["chatID"] as? UUID else { return }
            let autoNavigate = notification.userInfo?["autoNavigate"] as? Bool == true
            Task { @MainActor [weak self] in
                self?.handleEmailReviewChatCreated(chatID: chatID, autoNavigate: autoNavigate)
            }
        }

        let viewEmailObserver = NotificationCenter.default.addObserver(
            forName: .emailReviewViewEmail,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let emailID = notification.userInfo?["emailID"] as? UUID else { return }
            Task { @MainActor [weak self] in
                self?.showEmail(emailID)
            }
        }

        notificationObservers = [chatCreatedObserver, viewEmailObserver]
    }

    func stopNotificationBridge() {
        notificationBridgeUseCount = max(0, notificationBridgeUseCount - 1)
        guard notificationBridgeUseCount == 0 else { return }

        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
    }

    func selectChat(_ chatID: UUID) {
        selectedChatID = chatID
        selectedNavigationItem = .chats
        clearUnreadChatIfOpened()
    }

    func showEmail(_ emailID: UUID) {
        pendingEmailViewID = emailID
        selectedNavigationItem = .workspace
    }

    func openSettings(section: SettingsSection? = nil) {
        pendingSettingsSection = section
        #if os(iOS)
        selectedNavigationItem = .settings
        #endif
    }

    func clearPendingSettingsSection(_ section: SettingsSection) {
        guard pendingSettingsSection == section else { return }
        pendingSettingsSection = nil
    }

    func clearPendingEmailView() {
        pendingEmailViewID = nil
    }

    var hasUnreadChats: Bool {
        !unreadChatIDs.isEmpty
    }

    func hasUnreadMessages(in chatID: UUID) -> Bool {
        unreadChatIDs.contains(chatID)
    }

    func noteNewChatMessages(in chatID: UUID) {
        guard !isViewingChat(chatID) else { return }
        let inserted = unreadChatIDs.insert(chatID).inserted
        if inserted {
            syncDockBadge()
        }
    }

    func clearUnreadChatIfOpened() {
        guard let selectedChatID,
              isViewingChat(selectedChatID),
              clearUnreadMessages(in: selectedChatID) else { return }
    }

    private func handleEmailReviewChatCreated(chatID: UUID, autoNavigate: Bool) {
        guard autoNavigate else { return }
        selectChat(chatID)
    }

    @discardableResult
    func clearUnreadMessages(in chatID: UUID) -> Bool {
        guard unreadChatIDs.remove(chatID) != nil else { return false }
        syncDockBadge()
        return true
    }

    private func isViewingChat(_ chatID: UUID) -> Bool {
        selectedNavigationItem == .chats && selectedChatID == chatID
    }

    private func syncDockBadge() {
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = unreadChatIDs.isEmpty ? nil : "\(unreadChatIDs.count)"
        #endif
    }

    #if DEBUG
    func resetForTesting() {
        selectedNavigationItem = .home
        selectedChatID = nil
        pendingSettingsSection = nil
        unreadChatIDs.removeAll()
        pendingEmailViewID = nil
        syncDockBadge()
    }
    #endif
}
