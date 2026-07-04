import Foundation
import SwiftData

@Model
final class EmailThread {
    @Attribute(.unique) var id: UUID
    /// Account that owns this thread. Optional so older stores migrate, then
    /// `EmailRepository.resolveThreads()` backfills/splits legacy rows.
    var accountID: UUID?
    var subjectNormalized: String
    @Relationship(deleteRule: .cascade, inverse: \Email.thread)
    var messages: [Email]
    var firstDate: Date
    var lastDate: Date
    /// Last time an inbox-review pass included this thread. Set by
    /// `EmailReviewService.runOnce()` for every fetched thread (actioned or
    /// not) so "nothing-to-do" threads aren't re-sent to the LLM until new
    /// mail lands in them. Compared against `latestReviewableMessage.date`
    /// to decide whether a thread is current (no new mail since last review).
    var lastReviewedAt: Date?

    /// How many review passes have included this thread without new activity.
    /// `EmailRepository.resurfaceInterval(reviewedCount:)` owns the decay
    /// formula. Defaulted so existing stores migrate without a schema bump.
    var reviewedCount: Int = 0

    init(
        id: UUID = UUID(),
        accountID: UUID? = nil,
        subjectNormalized: String,
        messages: [Email] = [],
        firstDate: Date = .now,
        lastDate: Date = .now,
        lastReviewedAt: Date? = nil,
        reviewedCount: Int = 0
    ) {
        self.id = id
        self.accountID = accountID
        self.subjectNormalized = subjectNormalized
        self.messages = messages
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.lastReviewedAt = lastReviewedAt
        self.reviewedCount = reviewedCount
    }

    var sortedMessages: [Email] {
        messages.sorted { $0.date < $1.date }
    }

    var latestMessage: Email? {
        sortedMessages.last
    }

    var reviewableMessages: [Email] {
        sortedMessages.filter {
            !$0.isArchived
                && !$0.isDeleted
                && $0.role != .junk
                && $0.role != .drafts
        }
    }

    var latestReviewableMessage: Email? {
        reviewableMessages.last
    }

    var isReviewFlagged: Bool {
        hasFlaggedMessage(in: reviewableMessages)
    }

    /// True if any non-archived/deleted message in the thread carries a note.
    /// A notated thread is an explicit "this still matters" signal from the
    /// user (e.g. "revisit in two months"), so review selection keeps sending
    /// it to the model every pass rather than suppressing it.
    var hasReviewNote: Bool {
        reviewableMessages.contains { !$0.notes.isEmpty }
    }

    var reviewParticipantSummary: String {
        participantSummary(for: reviewableMessages)
    }

    var isFlagged: Bool {
        hasFlaggedMessage(in: messages)
    }

    var isArchived: Bool {
        !messages.isEmpty && messages.allSatisfy { $0.isArchived }
    }

    var unreadCount: Int {
        unreadCount(in: messages)
    }

    var participantSummary: String {
        participantSummary(for: messages)
    }

    private func hasFlaggedMessage(in messages: [Email]) -> Bool {
        messages.contains { $0.isFlagged }
    }

    private func unreadCount(in messages: [Email]) -> Int {
        messages.filter { !$0.isRead }.count
    }

    private func participantSummary(for messages: [Email]) -> String {
        let addresses = messages.flatMap { [$0.displayFromAddress] + $0.displayToAddresses }
        let unique = Array(NSOrderedSet(array: addresses)).compactMap { $0 as? String }
        return unique.prefix(3).joined(separator: ", ")
    }

    func matchesSearch(_ searchText: String) -> Bool {
        SearchQuery.matches(searchText, in: messages.flatMap(\.searchValues))
    }
}

@Model
final class Email {
    @Attribute(.unique) var id: UUID
    var messageID: String?
    var subject: String
    var fromAddress: String
    var toAddresses: [String]
    var ccAddresses: [String]
    var bccAddresses: [String]
    var date: Date
    var receivedAt: Date
    var bodyText: String
    var bodyHTML: String?
    var mailbox: String
    var folderRole: String = MailFolderRole.inbox.rawValue
    var isRead: Bool
    var isFlagged: Bool
    var isArchived: Bool
    var isDeleted: Bool
    var inReplyTo: String?
    var referencesRaw: [String]
    /// Identifies which configured account this message belongs to. Pre-
    /// multi-account rows get a fresh UUID on migration (default value below).
    var accountID: UUID
    var thread: EmailThread?
    @Relationship(deleteRule: .cascade, inverse: \EmailNote.email)
    var notes: [EmailNote]
    @Relationship(deleteRule: .cascade, inverse: \EmailAttachment.email)
    var attachments: [EmailAttachment]

    var uid: Int

    /// True for rows `upsertSentMessage` seeds locally to echo a just-sent
    /// reply before the Sent-folder sync picks it up. Carries a client-side
    /// synthetic uid + is promoted to the real server row when the matching
    /// `messageID` arrives via `upsertMessages`. See
    /// `EmailRepository.upsertSentMessage` for the full lifecycle.
    var isLocallySynthetic: Bool = false

    /// True when a local `isRead`/`isFlagged` change hasn't yet been confirmed
    /// by a successful server `setFlags`. Set by `EmailRepository`'s flag/read
    /// mutators, cleared by `EmailServerAction` once the server round-trip
    /// succeeds. Guards `reconcileFlagsFromSnapshot` from clobbering an
    /// unsynced local change with a stale server snapshot. Defaulted so
    /// existing stores migrate without a schema bump.
    var needsFlagSync: Bool = false

    init(
        id: UUID = UUID(),
        messageID: String? = nil,
        subject: String = "",
        fromAddress: String = "",
        toAddresses: [String] = [],
        ccAddresses: [String] = [],
        bccAddresses: [String] = [],
        date: Date = .now,
        receivedAt: Date = .now,
        bodyText: String = "",
        bodyHTML: String? = nil,
        mailbox: String = "INBOX",
        role: MailFolderRole = .inbox,
        isRead: Bool = false,
        isFlagged: Bool = false,
        isArchived: Bool = false,
        isDeleted: Bool = false,
        inReplyTo: String? = nil,
        referencesRaw: [String] = [],
        accountID: UUID = UUID(),
        uid: Int = 0,
        thread: EmailThread? = nil,
        notes: [EmailNote] = [],
        attachments: [EmailAttachment] = []
    ) {
        self.id = id
        self.messageID = messageID
        self.subject = subject
        self.fromAddress = fromAddress
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.bccAddresses = bccAddresses
        self.date = date
        self.receivedAt = receivedAt
        self.bodyText = bodyText
        self.bodyHTML = bodyHTML
        self.mailbox = mailbox
        self.folderRole = role.rawValue
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.isArchived = isArchived
        self.isDeleted = isDeleted
        self.inReplyTo = inReplyTo
        self.referencesRaw = referencesRaw
        self.accountID = accountID
        self.uid = uid
        self.thread = thread
        self.notes = notes
        self.attachments = attachments
    }

    var snippet: String {
        let trimmed = plainTextBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return trimmed.count > 140 ? String(trimmed.prefix(137)) + "..." : trimmed
    }

    var role: MailFolderRole {
        get { MailFolderRole(rawValue: folderRole) ?? .inbox }
        set { folderRole = newValue.rawValue }
    }

    /// Best-effort plain-text body for display. Prefers `bodyText` (server-
    /// provided text part). For HTML-only mail (common for newsletters,
    /// receipts, marketing), strips the HTML to plain text so the card still
    /// shows *something* instead of rendering blank. Lossy by design — block
    /// tags become newlines, other tags are dropped, common entities decoded.
    var plainTextBody: String {
        if !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bodyText
        }
        if let html = bodyHTML, !html.isEmpty {
            return Self.stripHTML(html)
        }
        return ""
    }

    /// Lossy HTML → plain-text conversion. Replaces block-level tags with
    /// newlines, strips remaining tags, decodes common entities, and collapses
    /// excessive blank lines.
    static func stripHTML(_ html: String) -> String {
        var s = html
        let blockEndings = ["</p>", "</div>", "</tr>", "</li>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>"]
        let blockSelfClosing = ["<br>", "<br/>", "<br />"]
        for tag in blockEndings {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        for tag in blockSelfClosing {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true }
            else if ch == ">" { inTag = false }
            else if !inTag { out.append(ch) }
        }
        out = out
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: { $0.isNewline })
        return lines.joined(separator: "\n")
    }

    var allReferenceIDs: [String] {
        var ids: [String] = []
        if let messageID, !messageID.isEmpty {
            ids.append(messageID)
        }
        if let inReplyTo, !inReplyTo.isEmpty {
            ids.append(inReplyTo)
        }
        ids.append(contentsOf: referencesRaw.filter { !$0.isEmpty })
        return ids
    }

    /// User-visible text that mailbox search runs over. Internal routing
    /// fields (mailbox name, message IDs, references) are deliberately
    /// excluded so queries only match content the user can see.
    var searchValues: [String] {
        [subject, displayFromAddress, plainTextBody]
            + displayToAddresses
            + ccAddresses.map(EmailAddressDisplayFormatter.string)
            + bccAddresses.map(EmailAddressDisplayFormatter.string)
            + notes.map(\.content)
            + attachments.map(\.filename)
    }
}

enum EmailNoteAuthor: String, Codable, Sendable {
    case user
    case ai
}

@Model
final class EmailNote {
    @Attribute(.unique) var id: UUID
    var email: Email?
    var authorRawValue: String
    var content: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        email: Email? = nil,
        author: EmailNoteAuthor = .user,
        content: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.email = email
        self.authorRawValue = author.rawValue
        self.content = content
        self.createdAt = createdAt
    }

    var author: EmailNoteAuthor {
        get { EmailNoteAuthor(rawValue: authorRawValue) ?? .user }
        set { authorRawValue = newValue.rawValue }
    }
}

@Model
final class EmailAttachment {
    @Attribute(.unique) var id: UUID
    var email: Email?
    var filename: String
    var filePath: String
    var mimeType: String
    var sizeBytes: Int

    init(
        id: UUID = UUID(),
        email: Email? = nil,
        filename: String = "",
        filePath: String = "",
        mimeType: String = "application/octet-stream",
        sizeBytes: Int = 0
    ) {
        self.id = id
        self.email = email
        self.filename = filename
        self.filePath = filePath
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }
}
