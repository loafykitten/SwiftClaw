import Foundation

/// Reconciles the vault's on-disk state against the last known state and
/// reports what changed. FSEvents are advisory hints that something in the
/// watched tree moved (per `FSEventStreamMonitor`) — this type never trusts
/// a hint's payload; every reported change comes from an actual rescan via
/// `stateProvider` (typically `NotesVault.enumerate()` + hashing).
/// `@Sendable` state provider/closures make this an **actor** that only
/// serializes its own bookkeeping (`knownState`, in-flight debounce), so a
/// hint-triggered rescan and an app-activation fallback rescan never race
/// each other.
actor VaultReconciler {
    /// A vault entry as of one rescan — the minimal state needed to diff
    /// against the previous rescan and to pair renames by matching content.
    struct VaultEntry: Sendable, Equatable {
        let relativePath: String
        let sha256: String
    }

    struct RenamedPair: Sendable, Equatable {
        let from: String
        let to: String
    }

    struct ReconcileDelta: Sendable, Equatable {
        let added: [String]
        let modified: [String]
        let removed: [String]
        let renamedPairs: [RenamedPair]

        var isEmpty: Bool {
            added.isEmpty && modified.isEmpty && removed.isEmpty && renamedPairs.isEmpty
        }

        static let empty = ReconcileDelta(added: [], modified: [], removed: [], renamedPairs: [])
    }

    typealias StateProvider = @Sendable () async throws -> [VaultEntry]
    typealias DeltaHandler = @Sendable (ReconcileDelta) async -> Void

    private let stateProvider: StateProvider
    private let debounceInterval: Duration

    private var knownState: [String: String] = [:]
    private var deltaHandler: DeltaHandler?
    private var eventConsumerTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// `debounceInterval` defaults to the plan's 1-second FSEvents debounce;
    /// tests inject a short interval to stay fast.
    init(stateProvider: @escaping StateProvider, debounceInterval: Duration = .seconds(1)) {
        self.stateProvider = stateProvider
        self.debounceInterval = debounceInterval
    }

    /// Starts consuming `events` — a bare "something changed" signal per
    /// hint, already stripped of FSEvents-specific payload by the caller —
    /// debouncing bursts into a single rescan `debounceInterval` after the
    /// last hint. `onDelta` fires for every non-empty delta, from either an
    /// event-triggered rescan or `rescanNow()`. Call at most once per
    /// instance; call `stop()` before discarding.
    func start(events: AsyncStream<Void>, onDelta: @escaping DeltaHandler) {
        deltaHandler = onDelta
        eventConsumerTask?.cancel()
        eventConsumerTask = Task { [weak self] in
            for await _ in events {
                await self?.scheduleDebouncedRescan()
            }
        }
    }

    func stop() {
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Full-scan fallback: callable directly on app activation and from a
    /// periodic timer while the Notes UI is visible. Always performs exactly
    /// one immediate rescan — it supersedes (cancels) any debounced rescan
    /// still pending — so it reliably catches state an FSEvent missed or
    /// coalesced away, independent of the event stream.
    @discardableResult
    func rescanNow() async -> ReconcileDelta {
        debounceTask?.cancel()
        debounceTask = nil
        return await performRescan()
    }

    private func scheduleDebouncedRescan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            _ = await self?.performRescan()
        }
    }

    @discardableResult
    private func performRescan() async -> ReconcileDelta {
        let entries: [VaultEntry]
        do {
            entries = try await stateProvider()
        } catch {
            return .empty
        }

        let newState = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.sha256) })
        let delta = Self.diff(previous: knownState, current: newState)
        knownState = newState

        if !delta.isEmpty {
            await deltaHandler?(delta)
        }
        return delta
    }

    /// Diffs two path→hash snapshots. Rename pairing only fires on stable
    /// evidence: a removed path and an added path that are each the *sole*
    /// candidate sharing a content hash. An ambiguous hash (shared by
    /// multiple removed and/or added paths) is left unpaired — those surface
    /// as ordinary adds/removes rather than a guessed pairing.
    private static func diff(previous: [String: String], current: [String: String]) -> ReconcileDelta {
        let previousPaths = Set(previous.keys)
        let currentPaths = Set(current.keys)

        let addedPaths = currentPaths.subtracting(previousPaths)
        let removedPaths = previousPaths.subtracting(currentPaths)
        let modifiedPaths = previousPaths.intersection(currentPaths).filter { previous[$0] != current[$0] }

        var removedByHash: [String: [String]] = [:]
        for path in removedPaths {
            removedByHash[previous[path]!, default: []].append(path)
        }
        var addedByHash: [String: [String]] = [:]
        for path in addedPaths {
            addedByHash[current[path]!, default: []].append(path)
        }

        var renamedPairs: [RenamedPair] = []
        var pairedRemoved = Set<String>()
        var pairedAdded = Set<String>()
        for (hash, removedCandidates) in removedByHash {
            guard removedCandidates.count == 1,
                  let addedCandidates = addedByHash[hash],
                  addedCandidates.count == 1 else { continue }
            renamedPairs.append(RenamedPair(from: removedCandidates[0], to: addedCandidates[0]))
            pairedRemoved.insert(removedCandidates[0])
            pairedAdded.insert(addedCandidates[0])
        }

        return ReconcileDelta(
            added: addedPaths.subtracting(pairedAdded).sorted(),
            modified: modifiedPaths.sorted(),
            removed: removedPaths.subtracting(pairedRemoved).sorted(),
            renamedPairs: renamedPairs.sorted { $0.from < $1.from }
        )
    }
}
