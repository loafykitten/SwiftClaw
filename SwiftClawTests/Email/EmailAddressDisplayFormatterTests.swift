import Testing
@testable import SwiftClaw

struct EmailAddressDisplayFormatterTests {
    @Test(arguments: [
        ("\"Priya Rao\" <priya@example.com>", "Priya Rao <priya@example.com>"),
        ("\"Vendor Billing\"", "Vendor Billing"),
        ("\"Bob \\\"Ops\\\" Smith\" <bob@example.com>", "Bob \"Ops\" Smith <bob@example.com>"),
        ("Priya Rao <priya@example.com>", "Priya Rao <priya@example.com>"),
        ("\"Priya Rao\" priya@example.com", "\"Priya Rao\" priya@example.com"),
    ])
    func formatsAddress(_ input: String, _ expected: String) {
        #expect(EmailAddressDisplayFormatter.string(input) == expected)
    }
}
