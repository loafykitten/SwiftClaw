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
                    date: "Jun 24, 2026 at 10:00 PM"
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
        #expect(decoded.reviewType == .email)
        #expect(decoded.items.count == 2)
        #expect(decoded.items[0].action == .flag)
        #expect(decoded.items[0].date == "Jun 24, 2026 at 10:00 PM")
        #expect(decoded.items[1].action == .delete)
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

    @Test func actionTokenRoundTripsAllCases() throws {
        for token in ReviewActionToken.allCases {
            let item = ReviewItem(
                itemID: UUID(),
                actionToken: token,
                actionLabel: token.rawValue
            )
            let data = try JSONEncoder().encode(item)
            let decoded = try JSONDecoder().decode(ReviewItem.self, from: data)
            #expect(decoded.action == token)
        }
    }
}
