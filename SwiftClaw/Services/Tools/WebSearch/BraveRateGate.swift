import Foundation

/// Spaces outbound Brave Search requests so concurrent callers (the Web
/// Search tool, investigation sub-agents) collectively respect the
/// requests-per-second limit configured in Settings → Providers.
actor BraveRateGate {
    static let shared = BraveRateGate()

    private var nextAllowedTime = ContinuousClock.now

    /// Suspends until the caller is allowed to issue the next request.
    func waitTurn() async {
        let requestsPerSecond = SettingsStorage.loadBraveSearchRequestsPerSecond()
        let spacing = Duration.seconds(1.0 / requestsPerSecond)
        let now = ContinuousClock.now
        let scheduled = Swift.max(now, nextAllowedTime)
        nextAllowedTime = scheduled.advanced(by: spacing)

        let wait = now.duration(to: scheduled)
        if wait > .zero {
            try? await Task.sleep(for: wait)
        }
    }
}
