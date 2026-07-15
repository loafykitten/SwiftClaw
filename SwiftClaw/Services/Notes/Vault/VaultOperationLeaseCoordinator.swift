import Foundation

/// Reentrancy-safe primitive that lets a vault teardown/switch wait for any
/// in-flight "live vault operation" (currently: a `NoteProposalDispatcher`
/// approval's file mutation) to finish before the vault it's operating on is
/// torn down out from under it.
///
/// Two operations must never interleave unsafely:
/// - acquiring a lease (an approval is about to read/mutate the vault)
/// - beginning teardown (a vault switch/reset/reset is about to invalidate
///   `NotesFeatureModel`'s `vault`/`repository`)
///
/// `beginTeardownAndWaitForDrain()` marks teardown in progress (so
/// `acquireLease()` starts returning `nil` immediately — no new lease can be
/// acquired once teardown has begun) and then suspends until every
/// already-acquired lease has called `release()`. Teardowns themselves are a
/// FIFO single-owner queue: ownership passes directly from one completed
/// owner to the next without reopening lease acquisition between them. This
/// uses `withCheckedContinuation` rather than polling/sleeping, and every
/// method here is a plain synchronous `@MainActor` call except for those
/// suspension points, so there's no reentrancy hazard: nothing here calls back
/// into arbitrary caller code while holding state half-updated.
@MainActor
final class VaultOperationLeaseCoordinator {
    private(set) var isTeardownInProgress = false
    private var activeLeaseCount = 0
    private var drainContinuations: [CheckedContinuation<Void, Never>] = []
    private var teardownStartContinuations: [CheckedContinuation<Void, Never>] = []
    private var queuedTeardownContinuations: [CheckedContinuation<Teardown, Never>] = []
    private var queuedTeardownContinuationWaiters: [(minimumCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var activeTeardown: Teardown?

    init() {}

    /// A single held lease. Must be released exactly once — typically via a
    /// `defer` at the call site holding it — even on the failure/cancellation
    /// path, or a concurrent `beginTeardownAndWaitForDrain()` would hang
    /// forever waiting for a lease nobody will ever release.
    final class Lease {
        fileprivate weak var coordinator: VaultOperationLeaseCoordinator?
        private var released = false

        fileprivate init(coordinator: VaultOperationLeaseCoordinator) {
            self.coordinator = coordinator
        }

        @MainActor func release() {
            guard !released else { return }
            released = true
            coordinator?.releaseLease()
        }
    }

    /// The exclusive right to perform one teardown. `endTeardown(_:)` accepts
    /// only the coordinator's currently active token, so a prior owner cannot
    /// reopen leases while a queued successor is still clearing its vault.
    final class Teardown {
        fileprivate weak var coordinator: VaultOperationLeaseCoordinator?

        fileprivate init(coordinator: VaultOperationLeaseCoordinator) {
            self.coordinator = coordinator
        }
    }

    /// `nil` once teardown has begun — the caller must treat that exactly
    /// like "this vault is no longer available" (e.g. mark a proposal
    /// `.expired`), never retry-until-success.
    func acquireLease() -> Lease? {
        guard !isTeardownInProgress else { return nil }
        activeLeaseCount += 1
        return Lease(coordinator: self)
    }

    private func releaseLease() {
        activeLeaseCount = max(0, activeLeaseCount - 1)
        guard activeLeaseCount == 0, isTeardownInProgress, !drainContinuations.isEmpty else { return }
        let waiters = drainContinuations
        drainContinuations = []
        for continuation in waiters {
            continuation.resume()
        }
    }

    /// Marks teardown as beginning (blocking further `acquireLease()` calls)
    /// and suspends until it owns the teardown gate and every already-held
    /// lease has been released. Call this *before* mutating/clearing the vault
    /// state the leases protect; pass the returned token to
    /// `endTeardown(_:)` once that work fully finishes.
    func beginTeardownAndWaitForDrain() async -> Teardown {
        if activeTeardown != nil {
            return await withCheckedContinuation { continuation in
                queuedTeardownContinuations.append(continuation)
                let queueWaiters = queuedTeardownContinuationWaiters.filter {
                    queuedTeardownContinuations.count >= $0.minimumCount
                }
                queuedTeardownContinuationWaiters.removeAll {
                    queuedTeardownContinuations.count >= $0.minimumCount
                }
                for waiter in queueWaiters {
                    waiter.continuation.resume()
                }
            }
        }

        isTeardownInProgress = true
        let startWaiters = teardownStartContinuations
        teardownStartContinuations = []
        for waiter in startWaiters {
            waiter.resume()
        }

        let teardown = Teardown(coordinator: self)
        activeTeardown = teardown
        guard activeLeaseCount > 0 else { return teardown }
        await withCheckedContinuation { continuation in
            drainContinuations.append(continuation)
        }
        return teardown
    }

    /// Ends one teardown only when `teardown` is the currently active owner.
    /// If another caller queued behind it, transfer ownership directly while
    /// keeping `isTeardownInProgress` true; only the final owner reopens lease
    /// acquisition.
    func endTeardown(_ teardown: Teardown) {
        guard activeTeardown === teardown else { return }

        if !queuedTeardownContinuations.isEmpty {
            let continuation = queuedTeardownContinuations.removeFirst()
            let nextTeardown = Teardown(coordinator: self)
            activeTeardown = nextTeardown
            continuation.resume(returning: nextTeardown)
            return
        }

        activeTeardown = nil
        isTeardownInProgress = false
    }

    /// Deterministic test synchronization: returns immediately when teardown
    /// is already active, otherwise resumes as soon as the first owner starts
    /// it. This observes the exact state transition rather than relying on a
    /// scheduler yield.
    func waitUntilTeardownStarted() async {
        guard !isTeardownInProgress else { return }
        await withCheckedContinuation { continuation in
            teardownStartContinuations.append(continuation)
        }
    }

    /// Deterministic test synchronization for an overlapping teardown caller.
    /// It returns once the requested number of later callers have joined the
    /// FIFO queue.
    func waitUntilTeardownIsQueued(atLeast count: Int = 1) async {
        precondition(count > 0)
        guard queuedTeardownContinuations.count < count else { return }
        await withCheckedContinuation { continuation in
            queuedTeardownContinuationWaiters.append((count, continuation))
        }
    }
}
