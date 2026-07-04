import SwiftUI

struct EmailReviewFolderSettingsView: View {
    let account: StoredEmailAccount

    @State private var accountStore = EmailAccountStore.shared
    @State private var isRefreshing = false
    @State private var refreshMessage: String?

    private var currentAccount: StoredEmailAccount {
        accountStore.account(for: account.id) ?? account
    }

    private var customFolders: [MailFolderDescriptor] {
        (currentAccount.folders ?? [])
            .filter { $0.role == .custom }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Always reviewed") {
                Toggle("Inbox", isOn: .constant(true))
                    .disabled(true)
            }

            Section {
                if customFolders.isEmpty {
                    Text("No custom folders found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customFolders, id: \.name) { folder in
                        Toggle(folder.name, isOn: includedBinding(for: folder.name))
                    }
                }
            } header: {
                Text("Your folders")
            } footer: {
                Text("Included folders join the scheduled email review. The review's read/unread/flagged filters still apply. Spam, Sent, Drafts, Trash, and Archive are never reviewed automatically — ask in chat to check them.")
            }

            Section {
                Button {
                    refreshFolders()
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh Folder List", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)

                if let refreshMessage {
                    Text(refreshMessage)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(currentAccount.effectiveDisplayName)
    }

    private func includedBinding(for folderName: String) -> Binding<Bool> {
        Binding(
            get: {
                let normalized = EmailReviewFetchFilter.normalizeFolderName(folderName)
                return (currentAccount.reviewIncludedMailboxes ?? [])
                    .contains { EmailReviewFetchFilter.normalizeFolderName($0) == normalized }
            },
            set: { isIncluded in
                var updated = currentAccount
                var included = updated.reviewIncludedMailboxes ?? []
                let normalized = EmailReviewFetchFilter.normalizeFolderName(folderName)
                included.removeAll { EmailReviewFetchFilter.normalizeFolderName($0) == normalized }
                if isIncluded {
                    included.append(folderName)
                }
                updated.reviewIncludedMailboxes = included.isEmpty ? nil : included.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                accountStore.update(updated)
            }
        )
    }

    private func refreshFolders() {
        guard !ProcessInfo.processInfo.isRunningInPreview else {
            refreshMessage = "Folder refresh is unavailable in previews."
            return
        }

        isRefreshing = true
        refreshMessage = nil
        let account = currentAccount
        Task {
            do {
                let folders = try await SwiftMailClient(account: account).listFolders()
                refreshMessage = "Found \(folders.count) folder\(folders.count == 1 ? "" : "s")."
            } catch {
                refreshMessage = "Could not refresh folders."
            }
            isRefreshing = false
        }
    }
}
