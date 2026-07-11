import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// Settings › Notifications. The master toggle drives the one-time system
/// authorization prompt (`AppNotificationService.enableNotifications()`);
/// per-source toggles are gated on the master. Authorization status is
/// re-read on appear and whenever the scene becomes active again, so leaving
/// for System Settings and coming back refreshes the denied-state hint.
struct NotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var notificationService = AppNotificationService.shared

    @AppStorage(SettingsKeys.notificationsEnabled)
    private var notificationsEnabled = SettingsStorage.defaultNotificationsEnabled
    @AppStorage(SettingsKeys.notificationsNewMailEnabled)
    private var newMailEnabled = SettingsStorage.defaultNewMailNotificationsEnabled
    @AppStorage(SettingsKeys.notificationsReviewResultsEnabled)
    private var reviewResultsEnabled = SettingsStorage.defaultReviewResultNotificationsEnabled
    @AppStorage(SettingsKeys.notificationsChatRepliesEnabled)
    private var chatRepliesEnabled = SettingsStorage.defaultChatReplyNotificationsEnabled
    @AppStorage(SettingsKeys.notificationsCalendarAlertsEnabled)
    private var calendarAlertsEnabled = SettingsStorage.defaultCalendarAlertNotificationsEnabled

    private var isDenied: Bool {
        notificationService.authorizationStatus == .denied
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Notifications", isOn: $notificationsEnabled)
                if notificationsEnabled && isDenied {
                    deniedWarningRow
                }
            } footer: {
                Text("SwiftClaw posts notifications for background activity — new mail, finished inbox reviews, and chat replies that land while you're elsewhere. The dock badge is unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("New mail", isOn: $newMailEnabled)
                Toggle("Inbox review results", isOn: $reviewResultsEnabled)
                Toggle("Chat replies", isOn: $chatRepliesEnabled)
                Toggle("Calendar event alerts", isOn: $calendarAlertsEnabled)
            } header: {
                Text("Notify about")
            }
            .disabled(!notificationsEnabled)
        }
        .formStyle(.grouped)
        .onChange(of: notificationsEnabled) { _, isOn in
            CalendarAlertScheduler.shared.settingsDidChange()
            guard isOn else { return }
            Task {
                await notificationService.enableNotifications()
            }
        }
        .onChange(of: calendarAlertsEnabled) {
            // Reconcile promptly so switching alerts off also clears the
            // already-booked requests instead of letting them fire.
            CalendarAlertScheduler.shared.settingsDidChange()
        }
        .onAppear {
            Task { await notificationService.refreshAuthorizationStatus() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await notificationService.refreshAuthorizationStatus() }
        }
    }

    private var deniedWarningRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text("Notifications are turned off for SwiftClaw in System Settings, so nothing will be delivered.")
                    .font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            Spacer()
            #if os(macOS)
            Button("Open System Settings") {
                openNotificationSystemSettings()
            }
            #endif
        }
    }

    #if os(macOS)
    private func openNotificationSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
    #endif
}
