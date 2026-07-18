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

    @Test func cachePhaseCollapsesDetailedGreetingPhases() {
        #expect(HomeDayPhase.morningTwilight.cachePhase == .morning)
        #expect(HomeDayPhase.dawn.cachePhase == .morning)
        #expect(HomeDayPhase.morning.cachePhase == .morning)
        #expect(HomeDayPhase.afternoon.cachePhase == .afternoon)
        #expect(HomeDayPhase.evening.cachePhase == .evening)
        #expect(HomeDayPhase.eveningTwilight.cachePhase == .evening)
        #expect(HomeDayPhase.dusk.cachePhase == .evening)
    }

    @MainActor
    @Test func generatedContentCacheRequiresAnExactKeyMatch() {
        let cache = HomeGeneratedContentCache()
        let location = HomeDayGreetingLocationKey.approximate(
            latitude: 41.8781,
            longitude: -87.6298,
            timeZoneIdentifier: "America/Chicago"
        )
        let key = HomeGeneratedContentCache.Key(
            phase: .morning,
            persona: "warm",
            model: "test-model",
            location: location
        )
        cache.store(greeting: "Morning, Ember!", blurb: "Purr the build green.", for: key)

        #expect(cache.content(for: key) == HomeGeneratedContentCache.Content(
            greeting: "Morning, Ember!",
            blurb: "Purr the build green."
        ))
        #expect(cache.content(for: .init(
            phase: .afternoon,
            persona: key.persona,
            model: key.model,
            location: key.location
        )) == nil)
        #expect(cache.content(for: .init(
            phase: key.phase,
            persona: "focused",
            model: key.model,
            location: key.location
        )) == nil)
        #expect(cache.content(for: .init(
            phase: key.phase,
            persona: key.persona,
            model: "other-model",
            location: key.location
        )) == nil)
        #expect(cache.content(for: .init(
            phase: key.phase,
            persona: key.persona,
            model: key.model,
            location: .unavailable(timeZoneIdentifier: "America/Chicago")
        )) == nil)
    }
}
