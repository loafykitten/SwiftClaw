import Foundation

@MainActor
enum EmailMailClientResolver {
    static func mailClient(for email: Email) -> MailClient? {
        mailClient(forAccountID: email.accountID)
    }

    static func mailClient(forAccountID accountID: UUID) -> MailClient? {
        guard let account = EmailAccountStore.shared.account(for: accountID),
              account.isComplete else {
            return nil
        }
        return SwiftMailClient(account: account)
    }
}
