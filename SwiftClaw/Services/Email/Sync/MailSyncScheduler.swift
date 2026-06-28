import Foundation
import os

/// Pluggable mail-sync scheduler. Reviewed: there are three implementations
/// (foreground `Task`+`Task.sleep` loop always on; `#if os(macOS)`
/// `NSBackgroundActivityScheduler` opportunistic supplement; `#if os(iOS)`
/// `BGTaskScheduler` planned for the iOS build target). The factory picks
/// the right mix.
protocol MailSyncScheduler: AnyObject, Sendable {
    func start()
    func stop()
    func refreshNow() async
    var lastSyncDate: Date? { get }
}

/// Cross-platform baseline scheduler. Always-on `Task` + `Task.sleep` loop.
/// Mirrors the cadence of `BraveRateGate` / `InvestigationEngine`.
final class ForegroundLoopMailSyncScheduler: MailSyncScheduler, @unchecked Sendable {
    private static let logger = AppLog.make("mail.sync.scheduler")

    private let worker: MailSyncWorker
    private let intervalProvider: () -> Int
    private var loopTask: Task<Void, Never>?
    private var lastSync: Date?

    init(worker: MailSyncWorker, intervalProvider: @escaping () -> Int) {
        self.worker = worker
        self.intervalProvider = intervalProvider
    }

    var lastSyncDate: Date? { lastSync }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = max(60, self.intervalProvider())
                let inserted = await self.worker.syncOnce()
                self.lastSync = .now
                Self.logger.info("""
                    foreground sync done — \(inserted, privacy: .public) new; \
                    sleeping \(interval, privacy: .public)s
                    """)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refreshNow() async {
        _ = await worker.syncOnce()
        lastSync = .now
    }
}

#if os(macOS)
import Foundation

/// Opportunistic macOS background scheduler supplement (sandbox-compatible).
/// Runs alongside `ForegroundLoopMailSyncScheduler` so the foreground loop is
/// the consistent baseline and this only fires when the system deems it a good
/// time to wake the app.
final class BackgroundActivityMailSyncScheduler: MailSyncScheduler, @unchecked Sendable {
    private static let logger = AppLog.make("mail.sync.scheduler.background")

    private let worker: MailSyncWorker
    private let intervalProvider: () -> Int
    private let scheduler: NSBackgroundActivityScheduler
    private var lastSync: Date?

    init(worker: MailSyncWorker, intervalProvider: @escaping () -> Int) {
        self.worker = worker
        self.intervalProvider = intervalProvider
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.caffeineplz.SwiftClaw.mail-sync")
        scheduler.repeats = true
        scheduler.interval = TimeInterval(max(60, intervalProvider()))
        scheduler.qualityOfService = .utility
        self.scheduler = scheduler
    }

    var lastSyncDate: Date? { lastSync }

    func start() {
        scheduler.schedule { [weak self] completion in
            guard let self else {
                completion(.deferred)
                return
            }
            Task { @MainActor in
                _ = await self.worker.syncOnce()
                self.lastSync = .now
                completion(.deferred)
            }
        }
    }

    func stop() {
        scheduler.invalidate()
    }

    func refreshNow() async {
        _ = await worker.syncOnce()
        lastSync = .now
    }
}
#endif

enum MailSyncSchedulerFactory {
    /// Returns the schedulers appropriate for the current platform. The
    /// foreground loop is always included as the consistent baseline; on macOS
    /// we layer in `NSBackgroundActivityScheduler` as an opportunistic
    /// supplement.
    static func make(worker: MailSyncWorker, intervalProvider: @escaping () -> Int) -> [MailSyncScheduler] {
        var schedulers: [MailSyncScheduler] = [
            ForegroundLoopMailSyncScheduler(worker: worker, intervalProvider: intervalProvider)
        ]
        #if os(macOS)
        schedulers.append(BackgroundActivityMailSyncScheduler(worker: worker, intervalProvider: intervalProvider))
        #endif
        return schedulers
    }
}
