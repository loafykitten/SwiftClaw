import SwiftUI

struct EmailSettingsView: View {
    @AppStorage(SettingsKeys.emailEnabled) private var isEmailEnabled = SettingsStorage.defaultEmailEnabled
    @AppStorage(SettingsKeys.emailPollIntervalSeconds)
    private var pollIntervalSeconds = SettingsStorage.defaultEmailPollIntervalSeconds
    @AppStorage(SettingsKeys.emailReviewIntervalSeconds)
    private var reviewIntervalSeconds = SettingsStorage.defaultEmailReviewIntervalSeconds
    @AppStorage(SettingsKeys.emailReviewScheduleMode)
    private var reviewScheduleModeRaw = SettingsStorage.defaultEmailReviewScheduleMode.rawValue
    @AppStorage(SettingsKeys.emailReviewMaxThreads)
    private var reviewMaxThreads = SettingsStorage.defaultEmailReviewMaxThreads
    @AppStorage(SettingsKeys.emailReviewDefaultMaxAgeEnabled)
    private var reviewDefaultMaxAgeEnabled = SettingsStorage.defaultEmailReviewDefaultMaxAgeEnabled
    @AppStorage(SettingsKeys.emailReviewDefaultMaxAgeDays)
    private var reviewDefaultMaxAgeDays = SettingsStorage.defaultEmailReviewDefaultMaxAgeDays
    @AppStorage(SettingsKeys.emailReviewDefaultIncludeFlagged)
    private var reviewDefaultIncludeFlagged = SettingsStorage.defaultEmailReviewDefaultIncludeFlagged
    @AppStorage(SettingsKeys.emailReviewDefaultIncludeNotated)
    private var reviewDefaultIncludeNotated = SettingsStorage.defaultEmailReviewDefaultIncludeNotated
    @AppStorage(SettingsKeys.emailReviewDefaultIncludeRead)
    private var reviewDefaultIncludeRead = SettingsStorage.defaultEmailReviewDefaultIncludeRead
    @AppStorage(SettingsKeys.emailReviewDefaultIncludeUnread)
    private var reviewDefaultIncludeUnread = SettingsStorage.defaultEmailReviewDefaultIncludeUnread
    @AppStorage(SettingsKeys.emailReviewDefaultIncludeArchived)
    private var reviewDefaultIncludeArchived = SettingsStorage.defaultEmailReviewDefaultIncludeArchived
    @AppStorage(SettingsKeys.emailReviewDefaultIncludeTrashed)
    private var reviewDefaultIncludeTrashed = SettingsStorage.defaultEmailReviewDefaultIncludeTrashed
    @AppStorage(SettingsKeys.emailAutoNavigateToReviewChat)
    private var autoNavigateToReviewChat = SettingsStorage.defaultEmailAutoNavigateToReviewChat

    @State private var accountStore = EmailAccountStore.shared
    @State private var editingAccount: StoredEmailAccount? = nil
    @State private var presentingNewAccount: Bool = false
    @State private var dailyReviewTimes = SettingsStorage.loadEmailReviewDailyTimes()
    @State private var syncMonitor = MailSyncMonitor.shared

    /// Picker selection binding for the review interval. Reads the nearest
    /// offered option to the stored seconds (so a stale value still shows a
    /// real selection) and writes the chosen option's exact seconds.
    private var reviewIntervalSecondsBinding: Binding<Int> {
        Binding(
            get: { SettingsStorage.nearestEmailReviewIntervalSeconds(reviewIntervalSeconds) },
            set: { reviewIntervalSeconds = $0 }
        )
    }

    /// Picker selection binding for the sync (poll) interval.
    private var syncIntervalSecondsBinding: Binding<Int> {
        Binding(
            get: { SettingsStorage.nearestEmailSyncIntervalSeconds(pollIntervalSeconds) },
            set: { pollIntervalSeconds = $0 }
        )
    }

    /// Picker selection binding for emails-per-review. Snaps any stale stored
    /// value (e.g. from the old slider) to the nearest multiple of 5.
    private var reviewMaxThreadsSnappedBinding: Binding<Int> {
        Binding(
            get: {
                let range = SettingsStorage.emailReviewMaxThreadsRange
                let clamped = max(range.lowerBound, min(range.upperBound, reviewMaxThreads))
                return (clamped + 2) / 5 * 5
            },
            set: { reviewMaxThreads = $0 }
        )
    }

    private var reviewDefaultMaxAgeDaysBinding: Binding<Double> {
        Binding(
            get: { Double(reviewDefaultMaxAgeDays) },
            set: { reviewDefaultMaxAgeDays = Int($0.rounded()) }
        )
    }

    private var reviewDefaultMaxAgeDaysRange: ClosedRange<Double> {
        let lower = Double(SettingsStorage.emailReviewDefaultMaxAgeDaysRange.lowerBound)
        let upper = Double(SettingsStorage.emailReviewDefaultMaxAgeDaysRange.upperBound)
        return lower...upper
    }

    private var usesIntervalReviewSchedule: Bool {
        reviewScheduleModeRaw != EmailReviewScheduleMode.daily.rawValue
    }

    /// True when the sync interval is longer than the review interval —
    /// reviews would fire before fresh mail has been pulled.
    private var syncExceedsReviewInterval: Bool {
        pollIntervalSeconds > reviewIntervalSeconds
    }

    var body: some View {
        Form {
            // MARK: Enable

            Section {
                Toggle("Enable Email", isOn: $isEmailEnabled)
                Text("When enabled, the Email item appears in the sidebar and mail sync + inbox review run on the intervals below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Email")
            }

            // MARK: Accounts

            Section {
                if accountStore.accounts.filter(\.isComplete).isEmpty {
                    Text("No accounts configured.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(accountStore.accounts.filter(\.isComplete)) { account in
                        AccountRow(account: account) {
                            editingAccount = account
                        } onDelete: {
                            accountStore.remove(account)
                        }
                    }
                }
                Button {
                    presentingNewAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
            } header: {
                Text("Accounts")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if syncMonitor.isSyncing {
                        Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                    } else if let lastSyncDate = syncMonitor.lastSyncDate {
                        Text("Last synced \(lastSyncDate.formatted(.relative(presentation: .named)))")
                    }
                    #if os(iOS)
                    Text("Tap to edit. Swipe left to delete. Passwords are stored in the iOS Keychain.")
                    #else
                    Text("Tap to edit. Swipe left to delete. Passwords are stored in the macOS Keychain.")
                    #endif
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(!isEmailEnabled)

            // MARK: Schedule

            Section {
                Picker("Review Schedule", selection: $reviewScheduleModeRaw) {
                    ForEach(EmailReviewScheduleMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if usesIntervalReviewSchedule {
                    Picker("Review Interval", selection: reviewIntervalSecondsBinding) {
                        ForEach(EmailReviewIntervalOption.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    Text("How often the assistant reviews the inbox and creates a review chat when needed.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    dailyTimesEditor
                }

                Picker("Sync Interval", selection: syncIntervalSecondsBinding) {
                    ForEach(EmailSyncIntervalOption.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
                if syncExceedsReviewInterval {
                    Text("Reviews run more often than the inbox is pulled — they'll see stale mail. Consider a shorter sync interval.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("How often the inbox is pulled.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("Schedule")
            }
            .disabled(!isEmailEnabled)

            // MARK: Review scope

            Section {
                Picker("Emails per Review", selection: reviewMaxThreadsSnappedBinding) {
                    ForEach(Array(stride(from: 5, through: 100, by: 5)), id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.menu)
                Text("Most emails the inbox review looks at in one pass. Lower keeps each review cheaper and faster.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Toggle("Limit by age", isOn: $reviewDefaultMaxAgeEnabled)
                if reviewDefaultMaxAgeEnabled {
                    HStack {
                        Text("Max Age")
                        Spacer()
                        Text("\(reviewDefaultMaxAgeDays) day\(reviewDefaultMaxAgeDays == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: reviewDefaultMaxAgeDaysBinding,
                        in: reviewDefaultMaxAgeDaysRange,
                        step: 1
                    )
                }
            } header: {
                Text("Review scope")
            }
            .disabled(!isEmailEnabled)

            // MARK: Default filters

            Section {
                Toggle("Unread", isOn: $reviewDefaultIncludeUnread)
                Toggle("Read", isOn: $reviewDefaultIncludeRead)
                Toggle("Flagged", isOn: $reviewDefaultIncludeFlagged)
                Toggle("Notated", isOn: $reviewDefaultIncludeNotated)

                Text("Mailboxes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Archived", isOn: $reviewDefaultIncludeArchived)
                Toggle("Trash", isOn: $reviewDefaultIncludeTrashed)
            } header: {
                Text("Filter by status")
            } footer: {
                Text("Defines which mail a review pass scans by default. The Inbox is always in scope. A chat request can override these for a single review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!isEmailEnabled)

            // MARK: Notifications

            Section {
                Toggle("Auto-navigate to review chat", isOn: $autoNavigateToReviewChat)
                Text("When off, a dock badge / toast is shown instead of switching to the new review chat.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Notifications")
            }
            .disabled(!isEmailEnabled)
        }
        .formStyle(.grouped)
        .opacity(isEmailEnabled ? 1 : 0.6)
        .sheet(isPresented: $presentingNewAccount) {
            EmailAccountEditorSheet(mode: .create, store: accountStore)
        }
        .sheet(item: $editingAccount) { account in
            EmailAccountEditorSheet(mode: .edit(account), store: accountStore)
        }
        .onChange(of: reviewScheduleModeRaw) { _, _ in
            notifyReviewScheduleChanged()
        }
        .onChange(of: reviewIntervalSeconds) { _, _ in
            notifyReviewScheduleChanged()
        }
        .onChange(of: dailyReviewTimes) { _, newValue in
            SettingsStorage.saveEmailReviewDailyTimes(newValue)
            notifyReviewScheduleChanged()
        }
    }

    private var dailyTimesEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(dailyReviewTimes.indices, id: \.self) { index in
                HStack {
                    DatePicker(
                        "Review Time",
                        selection: dailyTimeBinding(for: index),
                        displayedComponents: .hourAndMinute
                    )
                    Button {
                        removeDailyTime(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(dailyReviewTimes.count <= 1)
                    .help("Remove time")
                }
            }
            Button {
                addDailyTime()
            } label: {
                Label("Add Time", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    private func dailyTimeBinding(for index: Int) -> Binding<Date> {
        Binding(
            get: {
                let minutes = dailyReviewTimes.indices.contains(index)
                    ? dailyReviewTimes[index]
                    : SettingsStorage.defaultEmailReviewDailyTimes[0]
                return SettingsStorage.dailyReviewDate(
                    minutesAfterMidnight: minutes,
                    onDayContaining: Date()
                ) ?? Date()
            },
            set: { date in
                guard dailyReviewTimes.indices.contains(index) else { return }
                dailyReviewTimes[index] = SettingsStorage.dailyReviewMinutes(afterMidnightFrom: date)
                dailyReviewTimes = Array(Set(dailyReviewTimes)).sorted()
            }
        )
    }

    private func addDailyTime() {
        let next = ((dailyReviewTimes.last ?? SettingsStorage.defaultEmailReviewDailyTimes[0]) + 60)
            % (24 * 60)
        dailyReviewTimes = Array(Set(dailyReviewTimes + [next])).sorted()
    }

    private func removeDailyTime(at index: Int) {
        guard dailyReviewTimes.indices.contains(index), dailyReviewTimes.count > 1 else { return }
        dailyReviewTimes.remove(at: index)
    }

    private func notifyReviewScheduleChanged() {
        NotificationCenter.default.post(
            name: SettingsNotifications.emailReviewScheduleDidChange,
            object: nil
        )
    }
}

#Preview {
    EmailSettingsView()
}
