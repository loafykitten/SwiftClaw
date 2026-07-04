import Testing
@testable import SwiftClaw

struct EmailAddressDisplayFormatterTests {
    @Test func stripsQuotesAroundDisplayName() {
        #expect(
            EmailAddressDisplayFormatter.string("\"Priya Rao\" <priya@example.com>")
                == "Priya Rao <priya@example.com>"
        )
    }

    @Test func stripsQuotesAroundStandaloneDisplayName() {
        #expect(EmailAddressDisplayFormatter.string("\"Vendor Billing\"") == "Vendor Billing")
    }

    @Test func unescapesQuotedDisplayName() {
        #expect(
            EmailAddressDisplayFormatter.string("\"Bob \\\"Ops\\\" Smith\" <bob@example.com>")
                == "Bob \"Ops\" Smith <bob@example.com>"
        )
    }

    @Test func leavesAlreadyCleanAddressAlone() {
        #expect(
            EmailAddressDisplayFormatter.string("Priya Rao <priya@example.com>")
                == "Priya Rao <priya@example.com>"
        )
    }

    @Test func leavesMalformedQuotedAddressAlone() {
        #expect(
            EmailAddressDisplayFormatter.string("\"Priya Rao\" priya@example.com")
                == "\"Priya Rao\" priya@example.com"
        )
    }
}
