import Foundation

/// Deterministic notification identifiers. They double as dedupe/replacement
/// keys (posting with an identifier already delivered replaces it) and as the
/// removal keys used when the user reads the target in-app.
nonisolated enum NotificationIdentifier {
    static func chatReply(_ chatID: UUID) -> String {
        "chatreply.\(chatID.uuidString)"
    }

    static func review(_ chatID: UUID) -> String {
        "review.\(chatID.uuidString)"
    }

    static func mail(_ emailID: UUID) -> String {
        "mail.\(emailID.uuidString)"
    }

    static func mailDigest(_ accountID: UUID) -> String {
        "mail.digest.\(accountID.uuidString)"
    }

    static func research(_ sessionID: UUID) -> String {
        "research.\(sessionID.uuidString)"
    }

    /// One identifier per (event, fire date, content). The fire date
    /// participates so moving an event or alarm books a fresh request and
    /// retires the old one; the content fingerprint (stable across launches)
    /// does the same for title or all-day edits, which would otherwise leave
    /// a booked request showing stale text.
    static func calendarAlert(eventID: UUID, fireDate: Date, contentFingerprint: String) -> String {
        "\(calendarAlertPrefix)\(eventID.uuidString).\(Int64(fireDate.timeIntervalSinceReferenceDate)).\(contentFingerprint)"
    }

    static let calendarAlertPrefix = "calendar.alert."

    /// One identifier per (reminder, fire date, content). The fire date
    /// participates so completing a recurring master (which rolls `dueDate`
    /// forward) or moving the date-only alert time books a fresh request and
    /// retires the old one; the content fingerprint (stable across launches)
    /// does the same for title edits, which would otherwise leave a booked
    /// request showing stale text.
    static func reminderAlert(reminderID: UUID, fireDate: Date, contentFingerprint: String) -> String {
        "\(reminderAlertPrefix)\(reminderID.uuidString).\(Int64(fireDate.timeIntervalSinceReferenceDate)).\(contentFingerprint)"
    }

    static let reminderAlertPrefix = "reminder.alert."
}

/// Category + action identifiers registered in
/// `AppNotificationService.activate()`.
nonisolated enum NotificationCategoryID {
    static let newMail = "newMail"
}

nonisolated enum NotificationActionID {
    static let mailArchive = "mail.archive"
    static let mailDelete = "mail.delete"
    static let mailFlag = "mail.flag"
    static let mailReply = "mail.reply"
}

/// Small codable routing payload carried in every request's `userInfo` so the
/// delegate can navigate on tap. Kept to plain strings — `userInfo` is a
/// plist-typed dictionary, not an arbitrary object graph.
nonisolated struct NotificationRoutingPayload: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case chatReply
        case review
        case newMail
        case mailDigest
        case calendarEvent
        case reminder
        case research
    }

    let kind: Kind
    /// Chat ID for `chatReply`/`review`, email ID for `newMail`, account ID
    /// for `mailDigest`, event ID for `calendarEvent`, reminder ID for
    /// `reminder`, research-session ID for `research`.
    let targetID: UUID

    private enum UserInfoKey {
        static let kind = "swiftclaw.notification.kind"
        static let targetID = "swiftclaw.notification.targetID"
    }

    var userInfo: [AnyHashable: Any] {
        [
            UserInfoKey.kind: kind.rawValue,
            UserInfoKey.targetID: targetID.uuidString,
        ]
    }

    init(kind: Kind, targetID: UUID) {
        self.kind = kind
        self.targetID = targetID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kindRaw = userInfo[UserInfoKey.kind] as? String,
              let kind = Kind(rawValue: kindRaw),
              let idString = userInfo[UserInfoKey.targetID] as? String,
              let targetID = UUID(uuidString: idString) else {
            return nil
        }
        self.kind = kind
        self.targetID = targetID
    }
}

/// The per-message payload `MailSyncWorker` hands to
/// `AppNotificationService.notifyNewMail(_:)` for newly-inserted, unread
/// inbox messages.
nonisolated struct NewMailNotificationInfo: Sendable, Equatable {
    let emailID: UUID
    let accountID: UUID
    let fromDisplay: String
    let subject: String
    let snippet: String
}
