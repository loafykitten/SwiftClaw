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
    @AppStorage(SettingsKeys.notificationsReminderAlertsEnabled)
    private var reminderAlertsEnabled = SettingsStorage.defaultReminderAlertNotificationsEnabled
    @AppStorage(SettingsKeys.remindersAllDayAlertMinutes)
    private var remindersAllDayAlertMinutes = SettingsStorage.defaultRemindersAllDayAlertMinutes

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
                Toggle("Reminder alerts", isOn: $reminderAlertsEnabled)
                if reminderAlertsEnabled {
                    DatePicker(
                        "Time for reminders without a due time",
                        selection: allDayAlertTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                }
            } header: {
                Text("Notify about")
            }
            .disabled(!notificationsEnabled)
        }
        .formStyle(.grouped)
        .onChange(of: notificationsEnabled) { _, isOn in
            CalendarAlertScheduler.shared.settingsDidChange()
            ReminderAlertScheduler.shared.settingsDidChange()
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
        .onChange(of: reminderAlertsEnabled) {
            ReminderAlertScheduler.shared.settingsDidChange()
            // The calendar budget depends on whether reminder alerts can
            // book (36 shared vs 48 standalone).
            CalendarAlertScheduler.shared.settingsDidChange()
        }
        .onChange(of: remindersAllDayAlertMinutes) {
            // Date-only fire dates derive from this time; rebook them.
            ReminderAlertScheduler.shared.settingsDidChange()
        }
        .onAppear {
            Task { await notificationService.refreshAuthorizationStatus() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await notificationService.refreshAuthorizationStatus() }
        }
    }

    /// Bridges the minutes-after-midnight setting to the hour-and-minute
    /// `DatePicker`; the anchor day is irrelevant, only the wall-clock time
    /// is stored. Built from calendar components (not elapsed seconds after
    /// midnight) so a DST transition day can't shift the displayed time.
    private var allDayAlertTimeBinding: Binding<Date> {
        Binding {
            let calendar = Calendar.current
            return calendar.date(
                bySettingHour: remindersAllDayAlertMinutes / 60,
                minute: remindersAllDayAlertMinutes % 60,
                second: 0,
                of: .now
            ) ?? calendar.startOfDay(for: .now)
        } set: { newValue in
            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            remindersAllDayAlertMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
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
