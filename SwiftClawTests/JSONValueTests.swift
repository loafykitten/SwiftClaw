import Foundation
import Testing
@testable import SwiftClaw

struct JSONValueTests {
    @Test func intValueAcceptsWholeNumbers() {
        #expect(JSONValue.number(5).intValue == 5)
        #expect(JSONValue.number(-3).intValue == -3)
        #expect(JSONValue.number(0).intValue == 0)
    }

    @Test func intValueRejectsOutOfRangeAndNonFiniteNumbers() {
        #expect(JSONValue.number(1e100).intValue == nil)
        #expect(JSONValue.number(-1e100).intValue == nil)
        #expect(JSONValue.number(.infinity).intValue == nil)
        #expect(JSONValue.number(.nan).intValue == nil)
    }

    @Test func intValueRejectsFractionalAndNonNumericValues() {
        #expect(JSONValue.number(2.5).intValue == nil)
        #expect(JSONValue.string("5").intValue == nil)
    }

    /// The path a model's tool call takes: a huge literal decodes as a
    /// `Double` and must fall back to the tool's default instead of trapping.
    @Test func decodedHugeIntegerArgumentFallsBackToDefault() throws {
        let json = Data(#"{"query":"test","count":1e100}"#.utf8)
        let arguments = try JSONDecoder().decode([String: JSONValue].self, from: json)

        #expect(arguments["count"]?.intValue == nil)
        #expect(min(max(arguments["count"]?.intValue ?? 5, 1), 10) == 5)
    }
}
