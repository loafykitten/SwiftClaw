import Foundation
import Testing
@testable import SwiftClaw

@Suite("Research budget")
struct ResearchBudgetTests {
    @Test func concurrentLeasesStopAtConfiguredLimits() async {
        let configuration = makeConfiguration(searchCalls: 7, pageFetches: 5)
        let budget = ResearchBudget(configuration: configuration, startInstant: .now)

        let searchResults = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<50 {
                group.addTask { await budget.leaseSearchCall() }
            }
            var results = [Bool]()
            for await result in group {
                results.append(result)
            }
            return results
        }
        let fetchResults = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<50 {
                group.addTask { await budget.leasePageFetch() }
            }
            var results = [Bool]()
            for await result in group {
                results.append(result)
            }
            return results
        }

        #expect(searchResults.count(where: { $0 }) == 7)
        #expect(fetchResults.count(where: { $0 }) == 5)
        #expect(await budget.searchCallsSpent == 7)
        #expect(await budget.searchCallsRemaining == 0)
        #expect(await budget.pageFetchesSpent == 5)
        #expect(await budget.pageFetchesRemaining == 0)
        #expect(await budget.leaseSearchCall() == false)
        #expect(await budget.leasePageFetch() == false)
    }

    @Test func finalizationWindowStartsAtReserveBoundary() async {
        let start = ContinuousClock.now
        let configuration = makeConfiguration(
            searchCalls: 1,
            pageFetches: 1,
            totalBudget: .seconds(100),
            finalizationReserve: 0.2
        )
        let budget = ResearchBudget(configuration: configuration, startInstant: start)

        #expect(await budget.isInFinalizationWindow(now: start + .seconds(79.999)) == false)
        #expect(await budget.isInFinalizationWindow(now: start + .seconds(80)))
    }

    /// The investigation tier searched right up to its deadline before
    /// budgets existed; only page fetches (deep-only) stop at the window.
    @Test func finalizationWindowBlocksFetchLeasesButNotSearchLeases() async {
        let configuration = makeConfiguration(
            searchCalls: 5,
            pageFetches: 5,
            totalBudget: .seconds(60),
            finalizationReserve: 1.0
        )
        let budget = ResearchBudget(configuration: configuration, startInstant: .now)

        #expect(await budget.isInFinalizationWindow(now: .now))
        #expect(await budget.leaseSearchCall())
        #expect(await budget.leasePageFetch() == false)
    }

    private func makeConfiguration(
        searchCalls: Int,
        pageFetches: Int,
        totalBudget: Duration = .seconds(60),
        finalizationReserve: Double = 0
    ) -> ResearchConfiguration {
        ResearchConfiguration(
            maxThreads: 1,
            reflectionWaves: 0,
            searchCallBudget: searchCalls,
            pageFetchBudget: pageFetches,
            pagesPerThread: 1,
            sourceMode: .fetchPages(maxBytesPerPage: 1_000),
            verification: .none,
            reportStyle: .conversational,
            reportLength: .concise,
            clarify: false,
            planPreview: false,
            totalBudget: totalBudget,
            finalizationReserve: finalizationReserve
        )
    }
}
