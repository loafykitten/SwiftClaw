import Foundation
import Testing
@testable import SwiftClaw

struct VaultReconcilerTests {
    private actor EntryStore {
        private var entries: [VaultReconciler.VaultEntry] = []
        func set(_ entries: [VaultReconciler.VaultEntry]) { self.entries = entries }
        func snapshot() -> [VaultReconciler.VaultEntry] { entries }
    }

    private actor DeltaCollector {
        private(set) var deltas: [VaultReconciler.ReconcileDelta] = []
        func record(_ delta: VaultReconciler.ReconcileDelta) { deltas.append(delta) }
    }

    private func makeEventStream() -> (AsyncStream<Void>, AsyncStream<Void>.Continuation) {
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { continuation = $0 }
        return (stream, continuation)
    }

    @Test func debouncedEventTriggersRescanAfterQuiescence() async throws {
        let store = EntryStore()
        let reconciler = VaultReconciler(
            stateProvider: { await store.snapshot() },
            debounceInterval: .milliseconds(50)
        )
        let collector = DeltaCollector()
        let (stream, continuation) = makeEventStream()
        defer { continuation.finish() }

        _ = await reconciler.rescanNow() // establish an empty baseline
        await reconciler.start(events: stream) { delta in await collector.record(delta) }

        await store.set([.init(relativePath: "note.md", sha256: "hash1")])
        continuation.yield(())

        try await Task.sleep(for: .milliseconds(300))
        await reconciler.stop()

        let deltas = await collector.deltas
        #expect(deltas.count == 1)
        #expect(deltas.first?.added == ["note.md"])
    }

    @Test func burstOfEventsCoalescesIntoOneRescan() async throws {
        let store = EntryStore()
        let reconciler = VaultReconciler(
            stateProvider: { await store.snapshot() },
            debounceInterval: .milliseconds(80)
        )
        let collector = DeltaCollector()
        let (stream, continuation) = makeEventStream()
        defer { continuation.finish() }

        _ = await reconciler.rescanNow()
        await reconciler.start(events: stream) { delta in await collector.record(delta) }

        await store.set([.init(relativePath: "note.md", sha256: "hash1")])
        continuation.yield(())
        try await Task.sleep(for: .milliseconds(20))
        continuation.yield(())
        try await Task.sleep(for: .milliseconds(20))
        continuation.yield(())

        try await Task.sleep(for: .milliseconds(300))
        await reconciler.stop()

        let deltas = await collector.deltas
        #expect(deltas.count == 1)
    }

    @Test func fallbackRescanCatchesAChangeTheEventStreamMissed() async throws {
        let store = EntryStore()
        let reconciler = VaultReconciler(stateProvider: { await store.snapshot() })

        _ = await reconciler.rescanNow() // establish an empty baseline

        // Mutate state WITHOUT sending an event — simulates a dropped or
        // coalesced-away FSEvent. Only the periodic/activation fallback
        // (`rescanNow`) should be relied on to notice this.
        await store.set([.init(relativePath: "missed.md", sha256: "hash1")])

        let delta = await reconciler.rescanNow()
        #expect(delta.added == ["missed.md"])
    }

    @Test func renamePairingRequiresAUniqueHashMatch() async throws {
        let store = EntryStore()
        let reconciler = VaultReconciler(stateProvider: { await store.snapshot() })

        await store.set([.init(relativePath: "old.md", sha256: "hashA")])
        _ = await reconciler.rescanNow()

        await store.set([.init(relativePath: "new.md", sha256: "hashA")])
        let delta = await reconciler.rescanNow()

        #expect(delta.added.isEmpty)
        #expect(delta.removed.isEmpty)
        #expect(delta.renamedPairs == [VaultReconciler.RenamedPair(from: "old.md", to: "new.md")])
    }

    @Test func ambiguousHashMatchesAreNotPaired() async throws {
        let store = EntryStore()
        let reconciler = VaultReconciler(stateProvider: { await store.snapshot() })

        await store.set([
            .init(relativePath: "a.md", sha256: "sameHash"),
            .init(relativePath: "b.md", sha256: "sameHash")
        ])
        _ = await reconciler.rescanNow()

        await store.set([.init(relativePath: "c.md", sha256: "sameHash")])
        let delta = await reconciler.rescanNow()

        #expect(delta.renamedPairs.isEmpty)
        #expect(Set(delta.removed) == Set(["a.md", "b.md"]))
        #expect(delta.added == ["c.md"])
    }

    @Test func modifiedPathsAreReportedWhenHashChangesInPlace() async throws {
        let store = EntryStore()
        let reconciler = VaultReconciler(stateProvider: { await store.snapshot() })

        await store.set([.init(relativePath: "note.md", sha256: "hash1")])
        _ = await reconciler.rescanNow()

        await store.set([.init(relativePath: "note.md", sha256: "hash2")])
        let delta = await reconciler.rescanNow()

        #expect(delta.modified == ["note.md"])
        #expect(delta.added.isEmpty)
        #expect(delta.removed.isEmpty)
        #expect(delta.renamedPairs.isEmpty)
    }
}
