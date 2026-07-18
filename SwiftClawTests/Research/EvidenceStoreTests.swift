import Foundation
import Testing
@testable import SwiftClaw

@Suite("Evidence store")
struct EvidenceStoreTests {
    @Test func sourceNumbersAreStableAndDeduplicatedByURL() async {
        let store = EvidenceStore()

        let first = await store.register(title: "First title", url: "https://example.com/a")
        let second = await store.register(title: "Second", url: "https://example.com/b")
        let duplicate = await store.register(
            title: "A later title",
            url: "https://example.com/a"
        )

        #expect(first == 1)
        #expect(second == 2)
        #expect(duplicate == 1)
        #expect(await store.indices(forURLs: ["https://example.com/b", "missing"]) == [2])

        let sources = await store.numberedList()
        #expect(sources.count == 2)
        #expect(sources[0].index == 1)
        #expect(sources[0].title == "First title")
        #expect(sources[0].url == "https://example.com/a")
    }

    @Test func evidenceRoundTripsBySourceAndAsAWhole() async throws {
        let store = EvidenceStore()
        let sourceIndex = await store.register(title: "Source", url: "https://example.com")
        let retrievedAt = Date(timeIntervalSince1970: 1_234)

        let added = await store.addEvidence(
            sourceIndex: sourceIndex,
            url: "https://example.com",
            title: "Source",
            quote: "A directly quoted sentence.",
            claimSummary: "The source supports the claim.",
            retrievedAt: retrievedAt
        )

        #expect(await store.evidence(forSourceIndex: sourceIndex) == [added])
        #expect(await store.evidence(forSourceIndex: 99).isEmpty)
        #expect(await store.allEvidence() == [added])

        let encoded = try JSONEncoder().encode(added)
        #expect(try JSONDecoder().decode(EvidenceRecord.self, from: encoded) == added)
    }
}
