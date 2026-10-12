import Foundation
import Testing
@testable import SwiftClaw

struct AppLogMessageTests {
    private struct SampleError: Error, CustomStringConvertible {
        var description: String { "login failed for me@example.com" }
    }

    @Test func redactsUnannotatedStringsAndErrors() {
        let host = "imap.example.com"
        let message: AppLogMessage = "connect \(host) failed: \(SampleError())"

        #expect(message.text == "connect imap.example.com failed: login failed for me@example.com")
        #expect(message.redactedText == "connect <private> failed: <private>")
    }

    @Test func keepsPublicAnnotatedValues() {
        let mailbox = "INBOX"
        let message: AppLogMessage = "synced \(mailbox, privacy: .public)"

        #expect(message.redactedText == "synced INBOX")
    }

    @Test func numbersAndBooleansArePublicByDefault() {
        let count = 12
        let elapsed = 1.5
        let message: AppLogMessage = "fetched \(count) in \(elapsed)s, partial: \(false)"

        #expect(message.redactedText == "fetched 12 in 1.5s, partial: false")
    }

    @Test func explicitPrivacyOverridesNumericDefault() {
        let uid: UInt32 = 4242
        let message: AppLogMessage = "uid \(uid, privacy: .private)"

        #expect(message.text == "uid 4242")
        #expect(message.redactedText == "uid <private>")
    }

    @Test func literalOnlyMessagesAreUnchanged() {
        let message: AppLogMessage = "starting sync"

        #expect(message.redactedText == "starting sync")
    }
}
