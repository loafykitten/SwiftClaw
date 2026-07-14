import Foundation
import Testing
@testable import SwiftClaw

struct ReviewCardPayloadTests {
    @Test func roundTripsEmailPayload() throws {
        let payload = ReviewCardPayload(
            reviewType: .email,
            items: [
                ReviewItem(
                    itemID: UUID(),
                    actionToken: .flag,
                    actionLabel: "Flag",
                    summary: "Awaiting reply",
                    subject: "Q3 planning",
                    sender: "boss@example.com",
                    date: "Jun 24, 2026 at 10:00 PM",
                    accountLabel: "Work"
                ),
                ReviewItem(
                    itemID: UUID(),
                    actionToken: .delete,
                    actionLabel: "Delete",
                    summary: nil,
                    subject: nil,
                    sender: nil
                )
            ]
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ReviewCardPayload.self, from: data)

        #expect(decoded == payload)
    }

    @Test func preservesUnknownActionToken() throws {
        // Forward-compat: a future action token we don't recognize yet must
        // survive a round-trip without throwing.
        let json = """
        {
          "reviewType": "email",
          "items": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "itemID": "22222222-2222-2222-2222-222222222222",
              "actionToken": "summarize",
              "actionLabel": "Summarize",
              "summary": null,
              "subject": null,
              "sender": null
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ReviewCardPayload.self, from: json)
        #expect(decoded.items.count == 1)
        #expect(decoded.items[0].actionToken == "summarize")
        #expect(decoded.items[0].action == nil)
        #expect(decoded.items[0].accountLabel == nil)
    }

    @Test func preservesUnknownReviewType() throws {
        // Forward-compat: an unknown `reviewType` must NOT throw on decode
        // (otherwise `ChatMessage.reviewCard` silently nil's the whole card
        // via `try?`). It should fall back to `.unknown`.
        let json = """
        {
          "reviewType": "newsletter",
          "items": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ReviewCardPayload.self, from: json)
        #expect(decoded.reviewType == .unknown)
        #expect(decoded.items.isEmpty)
    }

    @Test func decodesKnownReviewTypes() throws {
        let json = """
        {
          "reviewType": "calendar",
          "items": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ReviewCardPayload.self, from: json)
        #expect(decoded.reviewType == .calendar)
    }
}
