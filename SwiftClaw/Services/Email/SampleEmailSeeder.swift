#if DEBUG
import Foundation
import SwiftData

/// Seeds two complete email accounts plus a small multi-account inbox when
/// launched with `-SwiftClawSeedSampleEmails`, so simulator/UI runs can
/// exercise the account picker, unified-inbox labels, and per-account
/// filtering without live IMAP credentials. Sibling of `SampleChatSeeder`
/// in `SwiftClawApp.swift`; DEBUG-only tooling, never compiled into release.
@MainActor
enum SampleEmailSeeder {
    static func seedIfRequested(into container: ModelContainer) {
        guard ProcessInfo.processInfo.arguments.contains("-SwiftClawSeedSampleEmails") else { return }

        let context = container.mainContext
        let store = EmailAccountStore.shared
        guard store.accounts.isEmpty,
              ((try? context.fetchCount(FetchDescriptor<Email>())) ?? 0) == 0 else { return }

        UserDefaults.standard.set(true, forKey: SettingsKeys.emailEnabled)

        let work = store.add(
            StoredEmailAccount(
                displayName: "Work",
                imapHost: "imap.work.example.com",
                imapUsername: "alex@work.example.com",
                smtpHost: "smtp.work.example.com",
                smtpUsername: "alex@work.example.com",
                fromAddress: "alex@work.example.com"
            )
        )
        let personal = store.add(
            StoredEmailAccount(
                displayName: "Personal",
                imapHost: "imap.personal.example.com",
                imapUsername: "alex@personal.example.com",
                smtpHost: "smtp.personal.example.com",
                smtpUsername: "alex@personal.example.com",
                fromAddress: "alex@personal.example.com"
            )
        )

        var uid = 0
        @discardableResult
        func insertThread(
            account: StoredEmailAccount,
            subject: String,
            from: String,
            body: String,
            minutesAgo: Double,
            isRead: Bool = false,
            isFlagged: Bool = false,
            isArchived: Bool = false,
            replyBody: String? = nil
        ) -> Email {
            let date = Date().addingTimeInterval(-minutesAgo * 60)
            let thread = EmailThread(
                accountID: account.id,
                subjectNormalized: subject.lowercased(),
                firstDate: date,
                lastDate: date
            )
            context.insert(thread)

            uid += 1
            let message = Email(
                messageID: "<seed-\(uid)@example.com>",
                subject: subject,
                fromAddress: from,
                toAddresses: [account.fromAddress],
                date: date,
                receivedAt: date,
                bodyText: body,
                isRead: isRead,
                isFlagged: isFlagged,
                isArchived: isArchived,
                accountID: account.id,
                uid: uid,
                thread: thread
            )
            context.insert(message)

            if let replyBody {
                uid += 1
                let replyDate = date.addingTimeInterval(20 * 60)
                let reply = Email(
                    messageID: "<seed-\(uid)@example.com>",
                    subject: "Re: \(subject)",
                    fromAddress: account.fromAddress,
                    toAddresses: [from],
                    date: replyDate,
                    receivedAt: replyDate,
                    bodyText: replyBody,
                    isRead: true,
                    accountID: account.id,
                    uid: uid,
                    thread: thread
                )
                context.insert(reply)
                thread.lastDate = replyDate
            }
            return message
        }

        let roadmap = insertThread(
            account: work,
            subject: "Q3 roadmap review",
            from: "priya@work.example.com",
            body: "Draft is up — can you leave comments on the sync section before Thursday's planning call?",
            minutesAgo: 42
        )
        let invoice = insertThread(
            account: work,
            subject: "Invoice #8841 due Friday",
            from: "billing@vendor.example.com",
            body: "Reminder: invoice #8841 for the June license renewal is due this Friday.",
            minutesAgo: 60 * 26,
            isRead: true,
            isFlagged: true
        )
        insertThread(
            account: work,
            subject: "Standup notes — Tuesday",
            from: "standup-bot@work.example.com",
            body: "Yesterday: sync reconciliation. Today: review pass polish. Blockers: none.",
            minutesAgo: 60 * 49,
            isRead: true,
            isArchived: true
        )
        let dinner = insertThread(
            account: personal,
            subject: "Dinner Saturday?",
            from: "sam@friends.example.com",
            body: "That new ramen place near the park finally opened — want to try it Saturday around 7?",
            minutesAgo: 12
        )
        insertThread(
            account: personal,
            subject: "Your package has shipped",
            from: "orders@shop.example.com",
            body: "Good news — your order #45-2210 is on the way and should arrive Thursday.",
            minutesAgo: 60 * 8,
            isRead: true
        )
        insertThread(
            account: personal,
            subject: "Photos from the lake",
            from: "mom@family.example.com",
            body: "Finally got around to uploading the photos from last weekend — link inside!",
            minutesAgo: 60 * 30,
            isRead: true,
            replyBody: "These are great, the sunset one is going on the wall. Thanks for sending!"
        )

        // A ready-made review chat so the review-card UI (account chips,
        // action buttons, metadata layout) is reachable without running a
        // live inference pass.
        let reviewChat = Chat(title: "Inbox review — sample", modelSelection: "claude-sonnet-5")
        context.insert(reviewChat)
        let dateFormat = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let card = ChatMessage(
            role: .assistant,
            content: "",
            sortIndex: 0,
            reviewCard: ReviewCardPayload(
                reviewType: .email,
                items: [
                    ReviewItem(
                        itemID: roadmap.id,
                        actionToken: .review,
                        actionLabel: "Review",
                        summary: "Comments requested on the sync section before Thursday's planning call",
                        subject: roadmap.subject,
                        sender: "\"Priya Rao\" <priya@work.example.com>",
                        date: roadmap.date.formatted(dateFormat),
                        accountLabel: "Work"
                    ),
                    ReviewItem(
                        itemID: invoice.id,
                        actionToken: .flag,
                        actionLabel: "Flag",
                        summary: "June license renewal invoice is due Friday",
                        subject: invoice.subject,
                        sender: "\"Vendor Billing\" <billing@vendor.example.com>",
                        date: invoice.date.formatted(dateFormat),
                        accountLabel: "Work"
                    ),
                    ReviewItem(
                        itemID: dinner.id,
                        actionToken: .reply,
                        actionLabel: "Reply",
                        summary: "Sam is waiting on an answer about Saturday dinner",
                        subject: dinner.subject,
                        sender: "\"Sam Alvarez\" <sam@friends.example.com>",
                        date: dinner.date.formatted(dateFormat),
                        accountLabel: "Personal"
                    ),
                ]
            )
        )
        card.chat = reviewChat
        reviewChat.appendMessage(
            role: .assistant,
            content: "Three items need attention — an invoice due Friday, roadmap comments, and a dinner reply."
        )

        try? context.save()
    }
}
#endif
