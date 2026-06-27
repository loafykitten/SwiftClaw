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
            .task {
                let incomplete = accountStore.accounts.filter { !$0.isComplete }
                incomplete.forEach { accountStore.remove($0) }
            }

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

// MARK: - Account row

private struct AccountRow: View {
    let account: StoredEmailAccount
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var horizontalOffset: CGFloat = 0
    @State private var showingDeleteConfirmation = false

    private let actionWidth: CGFloat = 80
    private var triggerDistance: CGFloat { actionWidth + 16 }
    private var maxDragDistance: CGFloat { max(actionWidth, triggerDistance) }
    private var revealProgress: Double {
        min(Double(abs(horizontalOffset) / triggerDistance), 1)
    }

    var body: some View {
        ZStack {
            swipeBackground
            rowContent
                .offset(x: horizontalOffset)
                .gesture(dragGesture)
        }
        .clipShape(Rectangle())
        .animation(.easeOut(duration: 0.16), value: horizontalOffset)
        .confirmationDialog(
            "Delete \(account.effectiveDisplayName)?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the account and its saved password. Mail already synced is kept.")
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
                .imageScale(.medium)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.effectiveDisplayName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(account.imapUsername)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .imageScale(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
    }

    private var swipeBackground: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.subheadline)
                Text("Delete")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(width: actionWidth)
            .frame(maxHeight: .infinity)
            .background(Color.red.opacity(0.25 + 0.75 * revealProgress))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(revealProgress == 0 ? 0 : 1)
        .accessibilityHidden(true)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                horizontalOffset = max(-maxDragDistance, min(0, value.translation.width))
            }
            .onEnded { value in
                horizontalOffset = 0
                if value.translation.width <= -triggerDistance {
                    showingDeleteConfirmation = true
                }
            }
    }
}

// MARK: - Account editor sheet

private struct EmailAccountEditorSheet: View {
    enum Mode {
        case create
        case edit(StoredEmailAccount)
    }

    let mode: Mode
    let store: EmailAccountStore

    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var imapHost: String = ""
    @State private var imapPort: Int = SettingsStorage.defaultEmailImapPort
    @State private var imapUsername: String = ""
    @State private var imapPassword: String = ""
    @State private var smtpHost: String = ""
    @State private var smtpPort: Int = SettingsStorage.defaultEmailSmtpPort
    @State private var smtpUsername: String = ""
    @State private var smtpPassword: String = ""
    @State private var fromAddress: String = ""

    @State private var isTesting: Bool = false
    @State private var testResult: TestResult?

    @State private var testTask: Task<Void, Never>?

    private var canConfirm: Bool {
        fieldsComplete && testResult?.isSuccess == true
    }

    private var fieldsComplete: Bool {
        !imapHost.isEmpty
            && !imapUsername.isEmpty
            && !imapPassword.isEmpty
            && !smtpHost.isEmpty
            && !smtpUsername.isEmpty
            && !smtpPassword.isEmpty
            && !fromAddress.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(mode.isEditing ? "Edit Account" : "Add Account")
                    .font(.headline)
                Spacer()
                Button("Cancel") { testTask?.cancel(); dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            Form {
                Section("General") {
                    TextField("Display Name", text: $displayName)
                        .autocorrectionDisabled()
                    TextField("From Address", text: $fromAddress)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("IMAP Host", text: $imapHost)
                        .autocorrectionDisabled()
                    SettingsIntegerField(label: "IMAP Port", value: $imapPort)
                    TextField("IMAP Username", text: $imapUsername)
                        .autocorrectionDisabled()
                    APIKeyField(title: "IMAP Password", text: $imapPassword)
                } header: {
                    Text("IMAP")
                } footer: {
                    Text("Gmail users: create an app-specific password at myaccount.google.com/apppasswords and use it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("SMTP Host", text: $smtpHost)
                        .autocorrectionDisabled()
                    SettingsIntegerField(label: "SMTP Port", value: $smtpPort)
                    TextField("SMTP Username", text: $smtpUsername)
                        .autocorrectionDisabled()
                    APIKeyField(title: "SMTP Password", text: $smtpPassword)
                } header: {
                    Text("SMTP")
                }

                Section {
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView().controlSize(.mini)
                            }
                            Text(isTesting ? "Testing…" : "Test Connection")
                        }
                    }
                    .disabled(!fieldsComplete || isTesting)

                    if let testResult {
                        switch testResult {
                        case .success:
                            Label("Connection successful. You can now confirm.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let reason):
                            Label(reason, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(mode.isEditing ? "Save" : "Add Account") {
                    confirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canConfirm)
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear(perform: hydrate)
    }

    private func hydrate() {
        guard case .edit(let account) = mode else { return }
        displayName = account.displayName
        imapHost = account.imapHost
        imapPort = account.imapPort
        imapUsername = account.imapUsername
        smtpHost = account.smtpHost
        smtpPort = account.smtpPort
        smtpUsername = account.smtpUsername
        fromAddress = account.fromAddress
        imapPassword = Keychain.string(forKey: EmailAccountKeychainKeys.imapPassword(for: account.id)) ?? ""
        smtpPassword = Keychain.string(forKey: EmailAccountKeychainKeys.smtpPassword(for: account.id)) ?? ""
    }

    private func runTest() {
        testTask?.cancel()
        testResult = nil
        isTesting = true
        let account = currentSnapshot()
        // In-memory password overrides let us validate the credentials BEFORE
        // persisting them to the Keychain (which only happens on confirm).
        // Without this, `SwiftMailClient.isConfigured` would read nil from
        // the Keychain and `testConnection` would throw `.notConfigured`,
        // leaving the confirm button permanently disabled.
        let imap = imapPassword
        let smtp = smtpPassword
        testTask = Task {
            do {
                try await SwiftMailClient(
                    account: account,
                    imapPasswordOverride: imap,
                    smtpPasswordOverride: smtp
                ).testConnection()
                await MainActor.run {
                    isTesting = false
                    testResult = .success
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func confirm() {
        let account = currentSnapshot()
        switch mode {
        case .create:
            store.add(account)
            store.setPassword(imapPassword, kind: .imap, for: account)
            store.setPassword(smtpPassword, kind: .smtp, for: account)
        case .edit:
            store.update(account)
            store.setPassword(imapPassword, kind: .imap, for: account)
            store.setPassword(smtpPassword, kind: .smtp, for: account)
        }
        dismiss()
    }

    /// Builds a snapshot of the current field state, reusing the original
    /// account's UUID when editing (so passwords set in Keychain match).
    private func currentSnapshot() -> StoredEmailAccount {
        StoredEmailAccount(
            id: mode.accountID ?? UUID(),
            displayName: displayName,
            imapHost: imapHost,
            imapPort: imapPort,
            imapUsername: imapUsername,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpUsername: smtpUsername,
            fromAddress: fromAddress
        )
    }

    private enum TestResult: Equatable {
        case success
        case failure(String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }
}

private extension EmailAccountEditorSheet.Mode {
    var isEditing: Bool {
        if case .edit = self { return true }
        return false
    }
    var accountID: UUID? {
        if case .edit(let account) = self { return account.id }
        return nil
    }
}

struct SettingsIntegerField: View {
    let label: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(label, value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
        }
    }
}

#Preview {
    EmailSettingsView()
}
