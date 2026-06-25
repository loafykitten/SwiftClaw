import SwiftUI

struct EmailSettingsView: View {
    @AppStorage(SettingsKeys.emailEnabled) private var isEmailEnabled = SettingsStorage.defaultEmailEnabled
    @AppStorage(SettingsKeys.emailPollIntervalSeconds)
    private var pollIntervalSeconds = SettingsStorage.defaultEmailPollIntervalSeconds
    @AppStorage(SettingsKeys.emailReviewIntervalSeconds)
    private var reviewIntervalSeconds = SettingsStorage.defaultEmailReviewIntervalSeconds
    @AppStorage(SettingsKeys.emailAutoNavigateToReviewChat)
    private var autoNavigateToReviewChat = SettingsStorage.defaultEmailAutoNavigateToReviewChat

    @State private var accountStore = EmailAccountStore.shared
    @State private var editingAccount: StoredEmailAccount? = nil
    @State private var presentingNewAccount: Bool = false

    private var pollIntervalMinutesBinding: Binding<Double> {
        Binding(
            get: { Double(pollIntervalSeconds) / 60.0 },
            set: { pollIntervalSeconds = Int(($0 * 60).rounded()) }
        )
    }

    private var reviewIntervalMinutesBinding: Binding<Double> {
        Binding(
            get: { Double(reviewIntervalSeconds) / 60.0 },
            set: { reviewIntervalSeconds = Int(($0 * 60).rounded()) }
        )
    }

    private var pollRangeMinutes: ClosedRange<Double> {
        let lower = Double(SettingsStorage.emailPollIntervalSecondsRange.lowerBound) / 60.0
        let upper = Double(SettingsStorage.emailPollIntervalSecondsRange.upperBound) / 60.0
        return lower...upper
    }

    private var reviewRangeMinutes: ClosedRange<Double> {
        let lower = Double(SettingsStorage.emailReviewIntervalSecondsRange.lowerBound) / 60.0
        let upper = Double(SettingsStorage.emailReviewIntervalSecondsRange.upperBound) / 60.0
        return lower...upper
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Email", isOn: $isEmailEnabled)
                Text("When enabled, the Email item appears in the sidebar and mail sync + inbox review run on the intervals below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Email")
            }

            Section {
                if accountStore.accounts.isEmpty {
                    Text("No accounts configured.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(accountStore.accounts) { account in
                        Button {
                            editingAccount = account
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.effectiveDisplayName)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(account.imapUsername)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                accountStore.remove(account)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
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
                Text("Tap an account to edit. Swipe to delete. Passwords are stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!isEmailEnabled)

            Section {
                HStack {
                    Text("Sync Interval")
                    Spacer()
                    Text("\(Int(pollIntervalMinutesBinding.wrappedValue)) min")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: pollIntervalMinutesBinding,
                    in: pollRangeMinutes,
                    step: 1
                )
                Text("How often the inbox is pulled.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                HStack {
                    Text("Review Interval")
                    Spacer()
                    Text("\(Int(reviewIntervalMinutesBinding.wrappedValue)) min")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: reviewIntervalMinutesBinding,
                    in: reviewRangeMinutes,
                    step: 5
                )
                Text("How often the assistant reviews the inbox and creates a review chat when needed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Toggle("Auto-navigate to review chat", isOn: $autoNavigateToReviewChat)
                Text("When off, a dock badge / toast is shown instead of switching to the new review chat.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Sync & Review")
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
