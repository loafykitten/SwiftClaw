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
    /// Feature row in Settings › Tools to scroll to and briefly outline —
    /// set when a disabled feature is tapped in Workspace.
    var pendingToolsFeatureHighlight: WorkspaceFeature?
    private(set) var unreadChatIDs: Set<UUID> = []
    var pendingEmailViewID: UUID?

    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var notificationBridgeUseCount = 0
    /// Backing store for the persisted unread set. Swappable in DEBUG so
    /// tests run against an isolated fixture instead of `.standard`.
    @ObservationIgnored private var unreadStore: UserDefaults = .standard

    private init() {
        unreadChatIDs = SettingsStorage.loadUnreadChatIDs(userDefaults: unreadStore)
        syncDockBadge()
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
        selectedNavigationItem = .workspace
    }

    func openSettings(section: SettingsSection? = nil, highlightingToolsFeature feature: WorkspaceFeature? = nil) {
        pendingSettingsSection = section
        pendingToolsFeatureHighlight = feature
        #if os(iOS)
        selectedNavigationItem = .settings
        #endif
    }

    func clearPendingSettingsSection(_ section: SettingsSection) {
        guard pendingSettingsSection == section else { return }
        pendingSettingsSection = nil
    }

    func clearPendingToolsFeatureHighlight(_ feature: WorkspaceFeature) {
        guard pendingToolsFeatureHighlight == feature else { return }
        pendingToolsFeatureHighlight = nil
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
            unreadChatsDidChange()
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
        unreadChatsDidChange()
        return true
    }

    private func isViewingChat(_ chatID: UUID) -> Bool {
        selectedNavigationItem == .chats && selectedChatID == chatID
    }

    /// Drops unread IDs whose chat no longer exists — e.g. after a store
    /// reset/migration or any deletion that bypassed the router — so a stale
    /// persisted entry can't badge the dock (or show a sidebar dot) forever.
    /// Called at bootstrap once the model container is available.
    func pruneUnreadChats(keeping existingChatIDs: Set<UUID>) {
        let pruned = unreadChatIDs.intersection(existingChatIDs)
        guard pruned != unreadChatIDs else { return }
        unreadChatIDs = pruned
        unreadChatsDidChange()
    }

    private func unreadChatsDidChange() {
        // NOTE for tests: the unit-test bundle is injected into the real app
        // (`TEST_HOST`), so `.standard` in a test process IS the developer's
        // actual app defaults. Any test that marks chats unread (directly or
        // via the notify tool) must first inject a fixture with
        // `resetForTesting(unreadStore:)`.
        SettingsStorage.saveUnreadChatIDs(unreadChatIDs, userDefaults: unreadStore)
        syncDockBadge()
    }

    private func syncDockBadge() {
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = unreadChatIDs.isEmpty ? nil : "\(unreadChatIDs.count)"
        #endif
    }

    #if DEBUG
    /// Resets in-memory routing state and points unread persistence at
    /// `unreadStore` (pass a `UserDefaultsFixture` so tests that mark chats
    /// unread don't write into `.standard` — which the app host shares with
    /// the real app). Deliberately does NOT persist the cleared set, so a
    /// trailing `resetForTesting()` restores `.standard` without wiping the
    /// developer's actual unread state.
    func resetForTesting(unreadStore: UserDefaults = .standard) {
        selectedNavigationItem = .home
        selectedChatID = nil
        pendingSettingsSection = nil
        pendingToolsFeatureHighlight = nil
        unreadChatIDs.removeAll()
        pendingEmailViewID = nil
        self.unreadStore = unreadStore
        syncDockBadge()
    }
    #endif
}
