import Foundation
import Testing
@testable import SwiftClaw

struct ResearchEngineParsingTests {
    // MARK: - decodeJSON

    @Test func decodeJSONToleratesProseAndFences() {
        let response = """
            Here is the plan:
            ```json
            {"overview":"Overview.","threads":[{"question":"Q?","query":"q"}]}
            ```
            """
        let plan = ResearchEngine.decodeJSON(ResearchPlan.self, from: response)
        #expect(plan?.threads.first?.query == "q")
    }

    /// A closing brace before the first opening brace used to trap while
    /// slicing `response[start...end]`.
    @Test func decodeJSONReturnsNilForReversedBraces() {
        for response in ["}{", "} not json {", "}"] {
            #expect(ResearchEngine.decodeJSON(ResearchPlan.self, from: response) == nil)
        }
    }

    // MARK: - citedClaims

    @Test func citationBeforePunctuationStaysWithItsSentence() {
        let claims = ResearchEngine.citedClaims(in: "The launch happened in 2020 [1]. Later it grew.")

        #expect(claims.map(\.text) == ["The launch happened in 2020 [1]."])
        #expect(claims.first?.sourceIndices == [1])
        #expect(claims.first?.isSubstantive == true)
    }

    /// `… 2020. [1]` used to drop the sentence (no citation inside it) and
    /// submit a bare "[1]" fragment for verification.
    @Test func citationAfterPunctuationAttachesToThePrecedingSentence() {
        let report = "The launch happened in 2020. [1] It was delayed twice by weather [2]."
        let claims = ResearchEngine.citedClaims(in: report)

        #expect(claims.map(\.text) == [
            "The launch happened in 2020. [1]",
            "It was delayed twice by weather [2].",
        ])
        #expect(claims.map(\.sourceIndices) == [[1], [2]])
        #expect(claims.map(\.isSubstantive) == [true, true])

        let firstMarker = (report as NSString).range(of: "[1]")
        #expect(claims.first?.markerOffset == NSMaxRange(firstMarker))
    }

    @Test func multipleTrailingCitationsAllAttachToThePrecedingSentence() {
        let claims = ResearchEngine.citedClaims(in: "Both sources agree on the date. [1] [3]")

        #expect(claims.count == 1)
        #expect(claims.first?.sourceIndices == [1, 3])
        #expect(claims.first?.text == "Both sources agree on the date. [1] [3]")
    }

    @Test func leadingCitationOnALineStaysItsOwnFragment() {
        let claims = ResearchEngine.citedClaims(in: "[2]\nUncited sentence here.")

        #expect(claims.map(\.text) == ["[2]"])
        #expect(claims.first?.isSubstantive == false)
    }
}
