import Foundation
import Testing
@testable import SwiftClaw

struct FuzzyMatcherTests {
    @Test func matchesACaseInsensitiveSubsequence() throws {
        let match = try #require(FuzzyMatcher.match(query: "nvt", in: "NotesVault.swift"))
        #expect(match.score > 0)
        #expect(match.ranges.count == 3)
    }

    @Test func consecutiveMatchesScoreHigherThanScatteredOnes() throws {
        let consecutive = try #require(FuzzyMatcher.match(query: "not", in: "NotesVault.swift"))
        let scattered = try #require(FuzzyMatcher.match(query: "nvt", in: "NotesVault.swift"))
        #expect(consecutive.score > scattered.score)
    }

    @Test func earlierMatchesScoreHigherThanLaterOnesOfEqualShape() throws {
        let early = try #require(FuzzyMatcher.match(query: "not", in: "NotesVault.swift"))
        let late = try #require(FuzzyMatcher.match(query: "swi", in: "NotesVault.swift"))
        #expect(early.score > late.score)
    }

    @Test func returnsNilWhenCharactersAreOutOfOrder() {
        #expect(FuzzyMatcher.match(query: "tnv", in: "NotesVault.swift") == nil)
    }

    @Test func returnsNilWhenACharacterIsMissing() {
        #expect(FuzzyMatcher.match(query: "nvz", in: "NotesVault.swift") == nil)
    }

    @Test func returnsNilForAnEmptyQueryOrCandidate() {
        #expect(FuzzyMatcher.match(query: "", in: "NotesVault.swift") == nil)
        #expect(FuzzyMatcher.match(query: "n", in: "") == nil)
    }

    @Test func mergesAdjacentMatchesIntoASingleRange() throws {
        let match = try #require(FuzzyMatcher.match(query: "abc", in: "abcxyz"))
        #expect(match.ranges.count == 1)
        #expect(match.ranges[0] == "abcxyz".startIndex..<"abcxyz".index("abcxyz".startIndex, offsetBy: 3))
    }
}
