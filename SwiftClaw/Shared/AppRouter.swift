import Foundation
import Observation

@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    var selectedNavigationItem: NavigationItem? = .home
    var selectedChatID: UUID?
    var unreadChatID: UUID?
    var pendingEmailViewID: UUID?

    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var notificationBridgeUseCount = 0

    private init() {}

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

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
        selectedNavigationItem = .email
    }

    func clearPendingEmailView() {
        pendingEmailViewID = nil
    }

    func clearUnreadChatIfOpened() {
        guard selectedNavigationItem == .chats,
              let unreadChatID,
              selectedChatID == unreadChatID else { return }

        self.unreadChatID = nil
        NotificationCenter.default.post(name: .emailReviewChatOpened, object: nil)
    }

    private func handleEmailReviewChatCreated(chatID: UUID, autoNavigate: Bool) {
        unreadChatID = chatID
        guard autoNavigate else { return }
        selectChat(chatID)
    }
}
