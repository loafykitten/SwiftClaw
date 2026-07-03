import Testing
@testable import SwiftClaw

struct HomeDayGreetingGeneratorTests {
    @Test func userNameHighlightSplitsFinalNameBeforePunctuation() {
        let parts = HomeDayGreetingGenerator.userNameHighlightParts(
            in: "Good morning Ember!",
            userName: "Ember"
        )

        #expect(parts == .init(prefix: "Good morning ", userName: "Ember", suffix: "!"))
    }

    @Test func userNameHighlightSupportsMultiWordNames() {
        let parts = HomeDayGreetingGenerator.userNameHighlightParts(
            in: "Fresh dawn Ember Sparks.",
            userName: "Ember Sparks"
        )

        #expect(parts == .init(prefix: "Fresh dawn ", userName: "Ember Sparks", suffix: "."))
    }

    @Test func userNameHighlightSkipsNamesThatAreNotFinal() {
        let parts = HomeDayGreetingGenerator.userNameHighlightParts(
            in: "Ember, fresh dawn!",
            userName: "Ember"
        )

        #expect(parts == nil)
    }

    @Test func userNameHighlightRequiresWordBoundary() {
        let parts = HomeDayGreetingGenerator.userNameHighlightParts(
            in: "Good morning TheEmber!",
            userName: "Ember"
        )

        #expect(parts == nil)
    }
}
