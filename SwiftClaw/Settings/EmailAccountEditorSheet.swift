import SwiftUI

/// Account list row + add/edit sheet + the settings integer field it owns.
/// Extracted from `EmailSettingsView.swift` along the account-management
/// concern boundary.
struct AccountRow: View {
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

struct EmailAccountEditorSheet: View {
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
            SheetHeader(title: mode.isEditing ? "Edit Account" : "Add Account") {
                testTask?.cancel()
                dismiss()
            }

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

            SheetFooter(
                confirmTitle: mode.isEditing ? "Save" : "Add Account",
                isDisabled: !canConfirm
            ) {
                confirm()
            }
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

/// Port input used by the IMAP/SMTP sections of the account editor sheet.
/// File-private (no other consumer).
fileprivate struct SettingsIntegerField: View {
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
