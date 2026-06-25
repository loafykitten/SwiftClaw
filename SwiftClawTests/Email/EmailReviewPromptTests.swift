import Foundation
import Testing
@testable import SwiftClaw

/// Phase 11 — asserts the structure of the prompts/descriptors the inbox
/// review builds. The pieces under test are pure value types (`Codable`
/// descriptors) so no SwiftData/network is touched.
struct EmailReviewPromptTests {
    @Test func threadDescriptorEncodesPromptPayloadKeys() throws {
        let thread = EmailReviewThreadDescriptor(
            threadID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            subject: "Q3 planning",
            latestMessageDate: "Jun 24, 2026 at 10:00 PM",
            participantSummary: "boss@example.com, me@example.com",
            snippet: "Let's sync on the roadmap.",
            unreadCount: 2,
            isFlagged: true,
            messages: [
                EmailReviewMessageDescriptor(
                    messageID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    subject: "Q3 planning",
                    fromAddress: "boss@example.com",
                    date: "Jun 24, 2026 at 10:00 PM",
                    snippet: "Let's sync on the roadmap.",
                    isRead: false,
                    isFlagged: true,
                    notes: [
                        EmailReviewNoteDescriptor(author: "ai", content: "Reviewed: awaiting reply")
                    ]
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(thread)
        let json = try #require(String(data: data, encoding: .utf8))

        // Keys the system/user prompt rely on being present in the JSON.
        #expect(json.contains("\"threadID\""))
        #expect(json.contains("\"subject\""))
        #expect(json.contains("\"latestMessageDate\""))
        #expect(json.contains("\"participantSummary\""))
        #expect(json.contains("\"snippet\""))
        #expect(json.contains("\"unreadCount\""))
        #expect(json.contains("\"isFlagged\""))
        #expect(json.contains("\"messages\""))
        #expect(json.contains("\"messageID\""))
        #expect(json.contains("\"fromAddress\""))
        #expect(json.contains("\"date\""))
        #expect(json.contains("\"isRead\""))
        #expect(json.contains("\"notes\""))
        #expect(json.contains("\"author\""))
        #expect(json.contains("\"content\""))
    }

    @Test func threadDescriptorRoundTrips() throws {
        let thread = EmailReviewThreadDescriptor(
            threadID: UUID(),
            subject: "Sprint review",
            latestMessageDate: "Jun 24, 2026 at 10:00 PM",
            participantSummary: "team@example.com",
            snippet: "Notes attached.",
            unreadCount: 0,
            isFlagged: false,
            messages: [
                EmailReviewMessageDescriptor(
                    messageID: UUID(),
                    subject: "Sprint review",
                    fromAddress: "team@example.com",
                    date: "Jun 24, 2026 at 10:00 PM",
                    snippet: "Notes attached.",
                    isRead: true,
                    isFlagged: false,
                    notes: []
                )
            ]
        )

        let data = try JSONEncoder().encode(thread)
        let decoded = try JSONDecoder().decode(EmailReviewThreadDescriptor.self, from: data)

        #expect(decoded.threadID == thread.threadID)
        #expect(decoded.subject == thread.subject)
        #expect(decoded.unreadCount == thread.unreadCount)
        #expect(decoded.messages.count == 1)
        #expect(decoded.messages[0].messageID == thread.messages[0].messageID)
        #expect(decoded.messages[0].notes.isEmpty)
    }

    @Test func noteDescriptorEncodesAuthorAndContent() throws {
        let note = EmailReviewNoteDescriptor(author: "user", content: "Follow up Friday")
        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(EmailReviewNoteDescriptor.self, from: data)

        #expect(decoded.author == "user")
        #expect(decoded.content == "Follow up Friday")
    }

    @Test func descriptorEncodesPromptedActionSchema() throws {
        // The system prompt instructs the model to emit:
        //   { "email_guid": "<UUID>", "action": "review"|..., "summary": "..." }
        // Because `EmailReviewAction` CodingKeys map to those exact snake_case
        // keys, decoding a model-produced payload must succeed.
        let guid = UUID().uuidString
        let json = """
        {
          "email_guid": "\(guid)",
          "action": "flag",
          "summary": "Needs follow-up"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(EmailReviewAction.self, from: json)
        #expect(decoded.emailGUID == guid)
        #expect(decoded.actionToken == "flag")
        #expect(decoded.summary == "Needs follow-up")
    }
}
