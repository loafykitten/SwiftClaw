#if os(macOS)
import Foundation
import Testing
@testable import SwiftClaw

struct FSEventStreamMonitorTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Races stream iteration against a timeout so a missed/coalesced event
    /// fails the test quickly instead of hanging the suite.
    private func firstEvent(
        from stream: AsyncStream<FSEventStreamMonitor.Event>,
        timeout: Duration
    ) async -> FSEventStreamMonitor.Event? {
        await withTaskGroup(of: FSEventStreamMonitor.Event?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test func stopIsIdempotentAndSafeToCallRepeatedly() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let monitor = FSEventStreamMonitor(paths: [directory.path], latency: 0.1)
        _ = monitor.start()

        monitor.stop()
        monitor.stop()
        monitor.stop()
        // No crash/hang across repeated stop() calls — cleanup happens
        // exactly once internally.
    }

    /// Real FSEvents integration test: watches a real temp directory, writes
    /// a file into it, and expects *some* eventual delta referencing that
    /// directory. FSEvents coalesces bursts and may report the directory
    /// rather than the individual file depending on timing, so this only
    /// asserts an event arrives whose path is a prefix/superstring match —
    /// never on exact event count or flag combination.
    @Test func deliversAnEventualEventAfterARealFilesystemChange() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // FSEvents reports fully symlink-resolved paths (e.g. `/private/var/...`
        // on macOS, where the temp directory is `/var/...`); match on the
        // unique directory name rather than the full path to stay robust to
        // that resolution difference.
        let directoryName = directory.lastPathComponent

        let monitor = FSEventStreamMonitor(paths: [directory.path], latency: 0.1)
        let stream = monitor.start()

        // Give the stream time to register on its dispatch queue before the
        // change happens, so the write isn't missed entirely.
        try await Task.sleep(for: .milliseconds(300))

        let fileURL = directory.appendingPathComponent("note.md")
        try Data("hello".utf8).write(to: fileURL)

        let event = await firstEvent(from: stream, timeout: .seconds(10))
        monitor.stop()

        let unwrapped = try #require(event, "expected an FSEvents delta within the timeout")
        #expect(unwrapped.path.contains(directoryName))
    }
}
#endif
