#if os(macOS)
import CoreServices
import Foundation
import os

/// Wraps an `FSEventStreamRef` and exposes filesystem change hints as an
/// `AsyncStream`. Events here are advisory only: FSEvents coalesces bursts
/// under its latency window and can report a path more than once, slightly
/// late, or with a flag combination that no longer matches the current
/// on-disk state. Consumers must re-stat (or re-hash) before trusting
/// anything about a reported path — this type never claims to be
/// authoritative.
///
/// `@unchecked Sendable`: the FSEvents C callback bridges from a private
/// dispatch queue into Swift via an `Unmanaged` context pointer, which is
/// inherently outside the type-system's isolation checking. `lock` guards
/// every stored property the callback and the public API can touch, so
/// state is never read or written concurrently from two threads at once.
nonisolated final class FSEventStreamMonitor: @unchecked Sendable {
    struct Event: Sendable {
        let path: String
        let flags: FSEventStreamEventFlags
        let eventID: FSEventStreamEventId
    }

    private static let logger = AppLog.make("files.fsevents")

    private let paths: [String]
    private let latency: CFTimeInterval
    private let queue = DispatchQueue(label: "com.caffeineplz.SwiftClaw.fsevents", qos: .utility)

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<Event>.Continuation?
    private var didStop = false

    /// `latency` defaults to ~0.7s, matching the Notes vault reconciler's
    /// tolerance for coalesced bursts of edits.
    init(paths: [String], latency: CFTimeInterval = 0.7) {
        self.paths = paths
        self.latency = latency
    }

    /// Starts the underlying `FSEventStreamRef` and returns a hot
    /// `AsyncStream` of events. Call at most once per instance — create a
    /// new monitor to restart. Cancelling iteration (or the enclosing task)
    /// tears the stream down via `onTermination`.
    func start() -> AsyncStream<Event> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds in
                guard let clientCallBackInfo else { return }
                let monitor = Unmanaged<FSEventStreamMonitor>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
                monitor.handleCallback(
                    numEvents: numEvents,
                    eventPaths: eventPaths,
                    eventFlags: eventFlags,
                    eventIds: eventIds
                )
            }

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
            ) else {
                Self.logger.error("FSEventStreamCreate failed for \(self.paths.count, privacy: .public) path(s)")
                continuation.finish()
                return
            }

            lock.lock()
            self.stream = stream
            lock.unlock()

            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    private func handleCallback(
        numEvents: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIds: UnsafePointer<FSEventStreamEventId>
    ) {
        guard let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }

        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        guard let continuation else { return }

        for index in 0..<numEvents {
            continuation.yield(Event(path: cfPaths[index], flags: eventFlags[index], eventID: eventIds[index]))
        }
    }

    /// Stops and releases the underlying stream, and finishes the
    /// `AsyncStream`. Safe to call more than once — from `onTermination`, an
    /// explicit caller, and `deinit` — cleanup runs exactly once.
    func stop() {
        lock.lock()
        guard !didStop else {
            lock.unlock()
            return
        }
        didStop = true
        let streamToStop = stream
        stream = nil
        let continuationToFinish = continuation
        continuation = nil
        lock.unlock()

        continuationToFinish?.finish()

        guard let streamToStop else { return }
        FSEventStreamStop(streamToStop)
        FSEventStreamInvalidate(streamToStop)
        FSEventStreamRelease(streamToStop)
    }

    deinit {
        stop()
    }
}
#endif
