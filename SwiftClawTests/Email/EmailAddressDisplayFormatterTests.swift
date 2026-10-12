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

    @Test func splitIgnoresCommasInsideQuotedNamesAndComments() {
        #expect(EmailAddressParser.split(
            "\"Smith, Alice\" <alice@example.com>, bob@example.com (Bob, Ops), Carol <carol@example.com>"
        ) == [
            "\"Smith, Alice\" <alice@example.com>",
            "bob@example.com (Bob, Ops)",
            "Carol <carol@example.com>",
        ])
        #expect(EmailAddressParser.split(" , a@example.com ,, ") == ["a@example.com"])
    }

    @Test(arguments: [
        ("Alice Smith <alice@example.com>", "Alice Smith", "alice@example.com"),
        ("\"Smith, Alice\" <alice@example.com>", "Smith, Alice", "alice@example.com"),
        ("\"Bob \\\"Ops\\\" Smith\" <bob@example.com>", "Bob \"Ops\" Smith", "bob@example.com"),
        ("<carol@example.com>", nil, "carol@example.com"),
    ] as [(String, String?, String)])
    func parsesMailbox(_ input: String, _ name: String?, _ address: String) {
        #expect(EmailAddressParser.mailbox(input) == .init(name: name, address: address))
    }

    @Test func bareAddressHasNoName() {
        #expect(EmailAddressParser.mailbox(" dave@example.com ") == .init(name: nil, address: "dave@example.com"))
    }

    @Test func listEntryRequotesNamesThatWouldSplit() {
        let entry = EmailAddressParser.listEntry("Smith, Alice <alice@example.com>")
        #expect(entry == "\"Smith, Alice\" <alice@example.com>")
        #expect(EmailAddressParser.split(entry + ", bob@example.com").count == 2)
        #expect(EmailAddressParser.listEntry("Alice <alice@example.com>") == "Alice <alice@example.com>")
    }
}
