import Foundation

/// Atomically leases the bounded work allowed during one research run.
actor ResearchBudget {
    private let searchCallLimit: Int
    private let pageFetchLimit: Int
    private let startInstant: ContinuousClock.Instant
    private let finalizationOffset: Duration

    private(set) var searchCallsSpent = 0
    private(set) var pageFetchesSpent = 0

    var searchCallsRemaining: Int {
        max(0, searchCallLimit - searchCallsSpent)
    }

    var pageFetchesRemaining: Int {
        max(0, pageFetchLimit - pageFetchesSpent)
    }

    init(configuration: ResearchConfiguration, startInstant: ContinuousClock.Instant) {
        searchCallLimit = max(0, configuration.searchCallBudget)
        pageFetchLimit = max(0, configuration.pageFetchBudget)
        self.startInstant = startInstant

        let components = configuration.totalBudget.components
        let totalSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        let reserve = min(max(configuration.finalizationReserve, 0), 1)
        finalizationOffset = .seconds(max(0, totalSeconds * (1 - reserve)))
    }

    /// Leases one Brave search call. Retries belonging to that call use the
    /// same lease.
    ///
    /// Deliberately a pure count: the investigation tier launched searches
    /// right up to its deadline before budgets existed, and must keep doing
    /// so. Deep-tier stages consult ``isInFinalizationWindow(now:)`` before
    /// launching new waves of work instead.
    func leaseSearchCall() -> Bool {
        guard searchCallsSpent < searchCallLimit else {
            return false
        }

        searchCallsSpent += 1
        return true
    }

    /// Leases one outbound page fetch.
    func leasePageFetch() -> Bool {
        guard !isInFinalizationWindow(now: .now), pageFetchesSpent < pageFetchLimit else {
            return false
        }

        pageFetchesSpent += 1
        return true
    }

    /// Whether new searches and fetches must stop so the run can finalize.
    func isInFinalizationWindow(now: ContinuousClock.Instant) -> Bool {
        now >= startInstant.advanced(by: finalizationOffset)
    }
}
