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
    @State private var successfulTestFingerprint: EmailAccountConnectionFingerprint?

    /// Values the validated fields held when the sheet opened. A field's
    /// error is only shown once the user changes it, so a pristine form
    /// doesn't open covered in "required" messages.
    @State private var fieldBaseline = ValidatedFieldBaseline()

    private struct ValidatedFieldBaseline {
        var fromAddress = ""
        var imapHost = ""
        var imapPort = SettingsStorage.defaultEmailImapPort
        var smtpHost = ""
        var smtpPort = SettingsStorage.defaultEmailSmtpPort
    }

    private func errorIfEdited<Value: Equatable>(
        _ message: String?,
        current: Value,
        baseline: Value
    ) -> String? {
        current == baseline ? nil : message
    }

    private var validation: EmailAccountValidation {
        EmailAccountValidator.validate(
            imapHost: imapHost,
            imapPort: imapPort,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            fromAddress: fromAddress
        )
    }

    private var canConfirm: Bool {
        fieldsComplete
            && validation.isValid
            && testResult?.isSuccess == true
            && successfulTestFingerprint == currentConnectionFingerprint
    }

    private var canTest: Bool {
        fieldsComplete && validation.isValid && !isTesting
    }

    private var fieldsComplete: Bool {
        !imapHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !imapUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !imapPassword.isEmpty
            && !smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !smtpUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !smtpPassword.isEmpty
            && !fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentConnectionFingerprint: EmailAccountConnectionFingerprint {
        EmailAccountConnectionFingerprint(
            imapHost: imapHost,
            imapPort: imapPort,
            imapUsername: imapUsername,
            imapPassword: imapPassword,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpUsername: smtpUsername,
            smtpPassword: smtpPassword,
            fromAddress: fromAddress
        )
    }

    var body: some View {
        Group {
            #if os(iOS)
            iOSBody
            #else
            macOSBody
            #endif
        }
        .onAppear(perform: hydrate)
        .onChange(of: currentConnectionFingerprint) { _, _ in
            successfulTestFingerprint = nil
            if testResult?.isSuccess == true {
                testResult = nil
            }
        }
    }

    private var sheetTitle: String {
        mode.isEditing ? "Edit Account" : "Add Account"
    }

    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            accountForm
                .navigationTitle(sheetTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel, action: cancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(mode.isEditing ? "Save" : "Add Account") {
                            confirm()
                        }
                        .disabled(!canConfirm)
                    }
                }
        }
    }
    #else
    private var macOSBody: some View {
        VStack(spacing: 0) {
            SheetHeader(title: sheetTitle, onCancel: cancel)

            accountForm

            SheetFooter(
                confirmTitle: mode.isEditing ? "Save" : "Add Account",
                isDisabled: !canConfirm
            ) {
                confirm()
            }
        }
        .frame(minWidth: 520, minHeight: 560)
    }
    #endif

    private var accountForm: some View {
        Form {
            Section("General") {
                TextField("Display Name", text: $displayName)
                    .autocorrectionDisabled()
                TextField("From Address", text: $fromAddress)
                    .autocorrectionDisabled()
                FieldErrorText(message: errorIfEdited(validation.fromAddress, current: fromAddress, baseline: fieldBaseline.fromAddress))
            }

            Section {
                TextField("IMAP Host", text: $imapHost)
                    .autocorrectionDisabled()
                FieldErrorText(message: errorIfEdited(validation.imapHost, current: imapHost, baseline: fieldBaseline.imapHost))
                SettingsIntegerField(label: "IMAP Port", value: $imapPort, error: errorIfEdited(validation.imapPort, current: imapPort, baseline: fieldBaseline.imapPort))
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
                FieldErrorText(message: errorIfEdited(validation.smtpHost, current: smtpHost, baseline: fieldBaseline.smtpHost))
                SettingsIntegerField(label: "SMTP Port", value: $smtpPort, error: errorIfEdited(validation.smtpPort, current: smtpPort, baseline: fieldBaseline.smtpPort))
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
                .disabled(!canTest)

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
    }

    private func cancel() {
        testTask?.cancel()
        dismiss()
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
        fieldBaseline = ValidatedFieldBaseline(
            fromAddress: account.fromAddress,
            imapHost: account.imapHost,
            imapPort: account.imapPort,
            smtpHost: account.smtpHost,
            smtpPort: account.smtpPort
        )
    }

    private func runTest() {
        guard canTest else {
            testResult = .failure(validation.firstMessage ?? "Complete every required connection field.")
            return
        }

        testTask?.cancel()
        testResult = nil
        isTesting = true
        let account = currentSnapshot()
        let fingerprint = currentConnectionFingerprint
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
                    if currentConnectionFingerprint == fingerprint {
                        successfulTestFingerprint = fingerprint
                        testResult = .success
                    } else {
                        successfulTestFingerprint = nil
                        testResult = .failure("Settings changed. Test the connection again.")
                    }
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    successfulTestFingerprint = nil
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func confirm() {
        guard canConfirm else {
            return
        }

        let account = currentSnapshot()
        switch mode {
        case .create:
            // Passwords land in the Keychain before the account is visible so
            // the immediate first sync below can authenticate.
            store.setPassword(imapPassword, kind: .imap, for: account)
            store.setPassword(smtpPassword, kind: .smtp, for: account)
            store.add(account)
            if account.isComplete {
                EmailWorkflowManager.shared.refreshAfterAccountAdded()
            }
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

private struct EmailAccountValidation: Equatable {
    var imapHost: String?
    var imapPort: String?
    var smtpHost: String?
    var smtpPort: String?
    var fromAddress: String?

    var isValid: Bool {
        firstMessage == nil
    }

    var firstMessage: String? {
        imapHost ?? imapPort ?? smtpHost ?? smtpPort ?? fromAddress
    }
}

private struct EmailAccountConnectionFingerprint: Equatable, Sendable {
    var imapHost: String
    var imapPort: Int
    var imapUsername: String
    var imapPassword: String
    var smtpHost: String
    var smtpPort: Int
    var smtpUsername: String
    var smtpPassword: String
    var fromAddress: String
}

private enum EmailAccountValidator {
    nonisolated static func validate(
        imapHost: String,
        imapPort: Int,
        smtpHost: String,
        smtpPort: Int,
        fromAddress: String
    ) -> EmailAccountValidation {
        EmailAccountValidation(
            imapHost: hostError(imapHost, label: "IMAP host"),
            imapPort: portError(imapPort, label: "IMAP port"),
            smtpHost: hostError(smtpHost, label: "SMTP host"),
            smtpPort: portError(smtpPort, label: "SMTP port"),
            fromAddress: emailAddressError(fromAddress)
        )
    }

    nonisolated private static func hostError(_ value: String, label: String) -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            return "\(label) is required."
        }

        if host.contains("://") || host.contains("/") {
            return "Enter a host name, not a URL."
        }

        if host.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "Host names can't contain spaces."
        }

        if host.caseInsensitiveCompare("localhost") == .orderedSame || isIPv4Address(host) {
            return nil
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy(isValidHostLabel) else {
            return "Enter a valid host name."
        }

        return nil
    }

    nonisolated private static func portError(_ value: Int, label: String) -> String? {
        (1...65_535).contains(value) ? nil : "\(label) must be between 1 and 65535."
    }

    nonisolated private static func emailAddressError(_ value: String) -> String? {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            return "From address is required."
        }

        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let localPart = parts.first,
              let domain = parts.last,
              !localPart.isEmpty,
              !domain.isEmpty,
              String(localPart).rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              hostError(String(domain), label: "Email domain") == nil else {
            return "Enter a valid email address."
        }

        return nil
    }

    nonisolated private static func isValidHostLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty,
              label.count <= 63,
              label.first != "-",
              label.last != "-" else {
            return false
        }

        return label.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == UnicodeScalar("-")
        }
    }

    nonisolated private static func isIPv4Address(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }

        return octets.allSatisfy { octet in
            guard let value = Int(octet) else {
                return false
            }
            return (0...255).contains(value)
        }
    }
}

private struct FieldErrorText: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

/// Port input used by the IMAP/SMTP sections of the account editor sheet.
/// File-private (no other consumer).
fileprivate struct SettingsIntegerField: View {
    let label: String
    @Binding var value: Int
    var error: String?

    var body: some View {
        LabeledContent(label) {
            TextField(label, value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 96)
        }

        FieldErrorText(message: error)
    }
}
