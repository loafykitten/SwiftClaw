import Testing
@testable import SwiftClaw

struct HomeDayGreetingGeneratorTests {
    @Test(arguments: [
        (
            "Good morning Ember!",
            "Ember",
            "Good morning |Ember|!"
        ),
        (
            "Fresh dawn Ember Sparks.",
            "Ember Sparks",
            "Fresh dawn |Ember Sparks|."
        ),
        ("Ember, fresh dawn!", "Ember", nil),
        ("Good morning TheEmber!", "Ember", nil),
    ])
    func highlightsOnlyANameAtTheEndOfTheGreeting(
        _ greeting: String,
        _ userName: String,
        _ expected: String?
    ) {
        let parts = HomeDayGreetingGenerator.userNameHighlightParts(in: greeting, userName: userName)
        #expect(parts.map { "\($0.prefix)|\($0.userName)|\($0.suffix)" } == expected)
    }
}
