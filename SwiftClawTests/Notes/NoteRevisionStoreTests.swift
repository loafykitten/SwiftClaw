import Foundation
import Testing
@testable import SwiftClaw

struct NoteRevisionStoreTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Deterministic, monotonically-advancing clock and suffix generator so
    /// pruning tests don't depend on wall-clock timing or risk two
    /// snapshots landing in the same millisecond.
    private nonisolated final class SequenceSource: @unchecked Sendable {
        private var current: Date
        private var counter = 0
        private let step: TimeInterval

        init(start: Date, step: TimeInterval) {
            self.current = start
            self.step = step
        }

        func nextDate() -> Date {
            defer { current = current.addingTimeInterval(step) }
            return current
        }

        func nextSuffix() -> String {
            defer { counter += 1 }
            return String(format: "%08d", counter)
        }
    }

    @Test func snapshotRoundTripsContent() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteRevisionStore(directory: directory)

        let revision = try await store.snapshot(key: "note.md", content: "hello world")
        #expect(revision.content == "hello world")
        #expect(revision.key == "note.md")

        let all = try await store.revisions(forKey: "note.md")
        #expect(all.count == 1)
        #expect(all.first?.preview == "hello world")
        #expect(all.first?.id == revision.id)
        #expect(try await store.revision(forKey: "note.md", id: revision.id)?.content == "hello world")
    }

    @Test func revisionsAreKeyedIndependently() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteRevisionStore(directory: directory)

        _ = try await store.snapshot(key: "a.md", content: "a content")
        _ = try await store.snapshot(key: "b.md", content: "b content")

        let aRevisions = try await store.revisions(forKey: "a.md")
        let bRevisions = try await store.revisions(forKey: "b.md")
        #expect(aRevisions.map(\.preview) == ["a content"])
        #expect(bRevisions.map(\.preview) == ["b content"])
    }

    @Test func revisionsAreOrderedNewestFirst() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sequence = SequenceSource(start: Date(timeIntervalSince1970: 0), step: 1)
        let store = NoteRevisionStore(
            directory: directory,
            clock: sequence.nextDate,
            idSuffixGenerator: sequence.nextSuffix
        )

        _ = try await store.snapshot(key: "note.md", content: "first")
        _ = try await store.snapshot(key: "note.md", content: "second")
        _ = try await store.snapshot(key: "note.md", content: "third")

        let revisions = try await store.revisions(forKey: "note.md")
        #expect(revisions.map(\.preview) == ["third", "second", "first"])
    }

    @Test func prunesToAtMostFiftyRevisionsPerKey() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sequence = SequenceSource(start: Date(timeIntervalSince1970: 0), step: 1)
        let store = NoteRevisionStore(
            directory: directory,
            clock: sequence.nextDate,
            idSuffixGenerator: sequence.nextSuffix
        )

        for index in 0..<60 {
            _ = try await store.snapshot(key: "note.md", content: "revision \(index)")
        }

        let revisions = try await store.revisions(forKey: "note.md")
        #expect(revisions.count == NoteRevisionStore.maxRevisionsPerKey)
        // The 10 oldest (0...9) should have been pruned; the newest survives.
        #expect(revisions.first?.preview == "revision 59")
        #expect(!revisions.contains { $0.preview == "revision 0" })
    }

    @Test func prunesRevisionsOlderThanThirtyDays() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sequence = SequenceSource(start: Date(timeIntervalSince1970: 0), step: 1)
        let store = NoteRevisionStore(
            directory: directory,
            clock: sequence.nextDate,
            idSuffixGenerator: sequence.nextSuffix
        )

        // First snapshot lands far enough in the past that a later snapshot
        // pushes it beyond the 30-day retention window.
        _ = try await store.snapshot(key: "note.md", content: "stale")

        let recentSequence = SequenceSource(
            start: Date(timeIntervalSince1970: 0).addingTimeInterval(31 * 24 * 60 * 60),
            step: 1
        )
        let laterStore = NoteRevisionStore(
            directory: directory,
            clock: recentSequence.nextDate,
            idSuffixGenerator: sequence.nextSuffix
        )
        _ = try await laterStore.snapshot(key: "note.md", content: "fresh")

        let revisions = try await laterStore.revisions(forKey: "note.md")
        #expect(revisions.map(\.preview) == ["fresh"])
    }

    @Test func listingReadsOnlyABoundedPreviewWhileRestoreLoadsTheFullSnapshot() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteRevisionStore(directory: directory)
        let content = String(repeating: "x", count: NoteRevisionStore.maxPreviewReadBytes * 2)
        let revision = try await store.snapshot(key: "large.md", content: content)

        let metadata = try #require(try await store.revisions(forKey: "large.md").first)
        #expect(metadata.preview.count == NoteRevisionPreview.maxCharacterCount + 1)
        #expect(metadata.preview.hasSuffix("…"))

        let restored = try #require(try await store.revision(forKey: "large.md", id: revision.id))
        #expect(restored.content == content)
    }
}
