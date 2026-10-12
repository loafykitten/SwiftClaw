import Foundation
import Testing
import SwiftData
@testable import SwiftClaw

/// `Email.isTrashed` was stored as `isDeleted`, which shadowed
/// `PersistentModel.isDeleted`. These pin the rename: existing on-disk rows
/// keep their soft-delete flag, and the two meanings no longer collide.
@MainActor
struct EmailTrashedMigrationTests {
    @Test func storeWrittenBeforeRenameKeepsSoftDeleteFlag() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("email-trashed-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("Email.store")
        let trashedID = UUID()
        let activeID = UUID()

        try Self.writeLegacyStore(at: storeURL, trashedID: trashedID, activeID: activeID)

        let container = try ModelContainer(
            for: Schema([Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self]),
            configurations: ModelConfiguration(url: storeURL)
        )
        let byID = Dictionary(
            uniqueKeysWithValues: try ModelContext(container).fetch(FetchDescriptor<Email>()).map { ($0.id, $0) }
        )
        #expect(byID.count == 2)
        #expect(byID[trashedID]?.isTrashed == true, "the pre-rename isDeleted column must carry over")
        #expect(byID[activeID]?.isTrashed == false)
        #expect(byID[trashedID]?.subject == "Trashed")

        let trashedFetch = FetchDescriptor<Email>(predicate: #Predicate { $0.isTrashed })
        #expect(try ModelContext(container).fetch(trashedFetch).map(\.id) == [trashedID])
    }

    @Test func softDeleteDoesNotReadAsContextDeletion() throws {
        let container = try ModelContainer(
            for: Email.self, EmailThread.self, EmailNote.self, EmailAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let email = Email(subject: "Trashed", isTrashed: true)
        context.insert(email)
        try context.save()

        #expect(email.isTrashed)
        #expect(!email.isDeleted, "a soft-deleted row is still live in its context")

        let refetched = try ModelContext(container).fetch(FetchDescriptor<Email>()).first
        #expect(refetched?.isTrashed == true)
        #expect(refetched?.isDeleted == false)

        context.delete(email)
        #expect(email.isDeleted, "context deletion is SwiftData's own isDeleted")
    }

    /// Writes one trashed and one active row through `LegacyEmailSchema`,
    /// whose `Email` entity still names the flag `isDeleted`. The container
    /// goes out of scope on return so the store is closed before reopening.
    private static func writeLegacyStore(at url: URL, trashedID: UUID, activeID: UUID) throws {
        let container = try ModelContainer(
            for: Schema([LegacyEmailSchema.Email.self]),
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        context.insert(LegacyEmailSchema.Email(id: trashedID, subject: "Trashed", isDeleted: true))
        context.insert(LegacyEmailSchema.Email(id: activeID, subject: "Active", isDeleted: false))
        try context.save()
    }
}

/// `Email`'s stored attributes as they were before the rename (relationships
/// left out — the reopen adds them). Nested so the entity is still named
/// `Email` without clashing with the app's model.
private enum LegacyEmailSchema {
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
        var folderRole: String = "inbox"
        var isRead: Bool
        var isFlagged: Bool
        var isArchived: Bool
        var isDeleted: Bool
        var inReplyTo: String?
        var referencesRaw: [String]
        var accountID: UUID
        var uid: Int
        var isLocallySynthetic: Bool = false
        var needsFlagSync: Bool = false
        var isReadSyncPending: Bool = false
        var isFlaggedSyncPending: Bool = false

        init(id: UUID, subject: String, isDeleted: Bool) {
            self.id = id
            self.messageID = "<\(id.uuidString)@example.com>"
            self.subject = subject
            self.fromAddress = "sender@example.com"
            self.toAddresses = []
            self.ccAddresses = []
            self.bccAddresses = []
            self.date = .now
            self.receivedAt = .now
            self.bodyText = ""
            self.bodyHTML = nil
            self.mailbox = isDeleted ? "Trash" : "INBOX"
            self.isRead = false
            self.isFlagged = false
            self.isArchived = false
            self.isDeleted = isDeleted
            self.inReplyTo = nil
            self.referencesRaw = []
            self.accountID = UUID()
            self.uid = 1
        }
    }
}
